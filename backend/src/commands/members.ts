import { z } from "zod";
import { canActForOthers, canBan, canSetRole, isAdmin } from "../authz";
import { findMember, type MemberRecord } from "../clubs/model";
import { errors } from "../http/errors";
import { upsert } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";

const displayName = z.string().trim().min(1, { error: "Escribe un nombre" }).max(40);
const nickname = z.string().trim().max(30).nullable();
const memberId = z.string().min(1).max(64);

async function target(ctx: CommandContext, id: string): Promise<MemberRecord> {
  const m = await findMember(ctx.db, ctx.club.id, id);
  if (!m) throw errors.notFound();
  return m;
}

function setStatement(ctx: CommandContext, id: string, sets: string, values: unknown[]) {
  return ctx.db
    .prepare(`UPDATE members SET ${sets}, updated_at = ? WHERE id = ? AND club_id = ?`)
    .bind(...values, ctx.now.toISOString(), id, ctx.club.id);
}

/** Jugador sin cuenta (el primo de alguien). El id lo genera la app, para poder cargarle datos offline. */
export const createGuest = command(
  z.object({ id: z.uuid(), displayName, nickname: nickname.optional() }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const at = ctx.now.toISOString();
    return {
      statements: [
        ctx.db
          .prepare(
            `INSERT INTO members (id, club_id, user_id, role, display_name, nickname, created_by, created_at, updated_at)
             VALUES (?, ?, NULL, 'guest', ?, ?, ?, ?, ?)`,
          )
          .bind(p.id, ctx.club.id, p.displayName, p.nickname ?? null, ctx.user.id, at, at),
      ],
      touched: [upsert("member", p.id)],
    };
  },
);

/** Nombre y apodo. Cada uno el suyo; el staff, los de los sin cuenta; owner y admin, los de todos. */
export const updateMember = command(
  z
    .object({ memberId, displayName: displayName.optional(), nickname: nickname.optional() })
    .refine((p) => p.displayName !== undefined || p.nickname !== undefined, { error: "Nada que cambiar" }),
  async (ctx, p) => {
    const t = await target(ctx, p.memberId);
    const actor = ctx.member.role;
    const allowed =
      t.id === ctx.member.id ||
      (t.role === "guest" && canActForOthers(actor)) ||
      (isAdmin(actor) && (t.role !== "owner" || actor === "owner"));
    if (!allowed) throw errors.forbidden();
    const sets: string[] = [];
    const values: unknown[] = [];
    if (p.displayName !== undefined) {
      sets.push("display_name = ?");
      values.push(p.displayName);
    }
    if (p.nickname !== undefined) {
      sets.push("nickname = ?");
      values.push(p.nickname);
    }
    return { statements: [setStatement(ctx, t.id, sets.join(", "), values)], touched: [upsert("member", t.id)] };
  },
);

export const setRole = command(
  z.object({ memberId, role: z.enum(["admin", "scorer", "player"]) }),
  async (ctx, p) => {
    const t = await target(ctx, p.memberId);
    if (t.status !== "active" || !canSetRole(ctx.member.role, t.role, p.role)) throw errors.forbidden();
    return {
      statements: [setStatement(ctx, t.id, "role = ?", [p.role])],
      touched: [upsert("member", t.id)],
      audit: [{ action: "member.setRole", entity: "member", entityKey: t.id, summary: { from: t.role, to: p.role } }],
    };
  },
);

export const ban = command(z.object({ memberId }), async (ctx, p) => {
  const t = await target(ctx, p.memberId);
  if (t.id === ctx.member.id || t.status === "banned" || !canBan(ctx.member.role, t.role)) throw errors.forbidden();
  return {
    statements: [setStatement(ctx, t.id, "status = 'banned'", []), ...releaseFromTeams(ctx, t.id)],
    touched: [upsert("member", t.id)],
    audit: [{ action: "member.ban", entity: "member", entityKey: t.id }],
  };
});

/**
 * En un torneo, quien se va o es expulsado deja libre su sitio en el equipo; y si era capitán, el
 * equipo se queda sin capitán hasta que el organizador nombre otro.
 */
function releaseFromTeams(ctx: CommandContext, memberId: string) {
  if (ctx.club.kind !== "tournament") return [];
  const at = ctx.now.toISOString();
  return [
    ctx.db
      .prepare(
        `INSERT INTO changes (club_id, entity, entity_key, op, at)
         SELECT club_id, 'teamPlayer', id, 'upsert', ? FROM team_players WHERE club_id = ? AND member_id = ? AND status = 'active'`,
      )
      .bind(at, ctx.club.id, memberId),
    ctx.db
      .prepare("UPDATE team_players SET status = 'removed', updated_at = ? WHERE club_id = ? AND member_id = ? AND status = 'active'")
      .bind(at, ctx.club.id, memberId),
    ctx.db
      .prepare(
        `INSERT INTO changes (club_id, entity, entity_key, op, at)
         SELECT club_id, 'team', id, 'upsert', ? FROM teams WHERE club_id = ? AND captain_member_id = ?`,
      )
      .bind(at, ctx.club.id, memberId),
    ctx.db
      .prepare("UPDATE teams SET captain_member_id = NULL, updated_at = ? WHERE club_id = ? AND captain_member_id = ?")
      .bind(at, ctx.club.id, memberId),
  ];
}

/** Quitar la expulsión no lo mete de vuelta: queda como "se fue" y vuelve con una invitación. */
export const unban = command(z.object({ memberId }), async (ctx, p) => {
  const t = await target(ctx, p.memberId);
  if (t.status !== "banned" || !canBan(ctx.member.role, t.role)) throw errors.forbidden();
  return {
    statements: [setStatement(ctx, t.id, "status = 'left'", [])],
    touched: [upsert("member", t.id)],
    audit: [{ action: "member.unban", entity: "member", entityKey: t.id }],
  };
});

/** Salir del servidor. Su perfil y sus estadísticas se quedan; puede volver con una invitación. */
export const leave = command(z.object({}).strict(), async (ctx) => {
  if (ctx.member.role === "owner") throw errors.ownerCannotLeave();
  if (ctx.club.kind === "tournament") {
    const captain = await ctx.db
      .prepare("SELECT 1 FROM teams WHERE club_id = ? AND captain_member_id = ? AND status <> 'withdrawn'")
      .bind(ctx.club.id, ctx.member.id)
      .first();
    if (captain) throw errors.invalidState("Eres capitán: nombra a otro antes de irte del torneo");
  }
  return {
    statements: [setStatement(ctx, ctx.member.id, "status = 'left'", []), ...releaseFromTeams(ctx, ctx.member.id)],
    touched: [upsert("member", ctx.member.id)],
  };
});
