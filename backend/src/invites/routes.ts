import { Hono } from "hono";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { findMember, findMemberByUser } from "../clubs/model";
import { errors } from "../http/errors";
import type { AppEnv } from "../types";
import { findInvite, isUsable, type InviteRecord } from "./model";
import { invitePage } from "./page";

export const inviteRoutes = new Hono<AppEnv>();

/** Lo que ve la app antes de aceptar: a qué servidor entra y con qué perfil. Sin sesión. */
inviteRoutes.get("/:code", async (c) => {
  const db = c.env.DB;
  const invite = await findInvite(db, c.req.param("code"));
  if (!invite || !isUsable(invite, new Date())) throw errors.inviteInvalid();
  const target = invite.targetMemberId ? await findMember(db, invite.clubId, invite.targetMemberId) : null;
  return c.json({
    club: { id: invite.clubId, name: invite.club.name, description: invite.club.description },
    role: invite.role,
    claim: target ? { displayName: target.displayName } : null,
    expiresAt: invite.expiresAt,
  });
});

inviteRoutes.post("/:code/accept", requireAuth, async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const user = c.var.auth.user;
  const invite = await findInvite(db, c.req.param("code"));
  if (!invite || !isUsable(invite, now)) throw errors.inviteInvalid();

  const existing = await findMemberByUser(db, invite.clubId, user.id);
  if (existing?.status === "banned") throw errors.bannedFromClub();
  // Reclamar un perfil exige no tener ya otro en el servidor (aunque se haya ido).
  if (existing?.status === "active" || (existing && invite.targetMemberId)) throw errors.alreadyMember();

  await claimUse(db, invite, now);
  try {
    const member = await joinClub(db, invite, user, existing?.id ?? null, now);
    await auditStatement(
      db,
      { clubId: invite.clubId, actorUserId: user.id, action: "invite.accept", entity: "member", entityKey: member.id, summary: { invite: invite.code } },
      now,
    ).run();
    return c.json({ club: { id: invite.clubId, name: invite.club.name }, member }, 201);
  } catch (e) {
    // Si no se pudo entrar, el uso no cuenta.
    await db.prepare("UPDATE invites SET uses = uses - 1 WHERE code = ?").bind(invite.code).run();
    throw e;
  }
});

/** Gasta un uso de forma atómica: dos personas no pueden llevarse el último a la vez. */
async function claimUse(db: D1Database, invite: InviteRecord, now: Date) {
  const claimed = await db
    .prepare(
      `UPDATE invites SET uses = uses + 1
        WHERE code = ? AND revoked_at IS NULL AND uses < max_uses AND expires_at > ?
        RETURNING uses`,
    )
    .bind(invite.code, now.toISOString())
    .first();
  if (!claimed) throw errors.inviteInvalid();
}

async function joinClub(
  db: D1Database,
  invite: InviteRecord,
  user: { id: string; displayName: string },
  leftMemberId: string | null,
  now: Date,
) {
  const at = now.toISOString();

  if (invite.targetMemberId) {
    const claimed = await db
      .prepare(
        `UPDATE members SET user_id = ?, role = 'player', claimed_at = ?, updated_at = ?
          WHERE id = ? AND club_id = ? AND user_id IS NULL AND status = 'active'
          RETURNING id, role, display_name`,
      )
      .bind(user.id, at, at, invite.targetMemberId, invite.clubId)
      .first<{ id: string; role: string; display_name: string }>();
    if (!claimed) throw errors.inviteInvalid();
    return { id: claimed.id, role: claimed.role, displayName: claimed.display_name };
  }

  if (leftMemberId) {
    // Vuelve alguien que se había ido: mismo perfil, con sus estadísticas.
    const back = await db
      .prepare("UPDATE members SET status = 'active', role = ?, updated_at = ? WHERE id = ? RETURNING id, role, display_name")
      .bind(invite.role, at, leftMemberId)
      .first<{ id: string; role: string; display_name: string }>();
    return { id: back!.id, role: back!.role, displayName: back!.display_name };
  }

  const id = crypto.randomUUID();
  try {
    await db
      .prepare(
        `INSERT INTO members (id, club_id, user_id, role, display_name, created_by, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(id, invite.clubId, user.id, invite.role, user.displayName, user.id, at, at)
      .run();
  } catch (e) {
    // Dos aceptaciones simultáneas del mismo usuario: gana la primera.
    if (String(e).includes("UNIQUE constraint failed")) throw errors.alreadyMember();
    throw e;
  }
  return { id, role: invite.role, displayName: user.displayName };
}

/** Página para el enlace que se comparte por WhatsApp: `/i/<CODE>`. */
export const invitePageRoutes = new Hono<AppEnv>();

invitePageRoutes.get("/:code", async (c) => {
  const invite = await findInvite(c.env.DB, c.req.param("code"));
  const usable = invite !== null && isUsable(invite, new Date());
  c.header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'");
  c.header("Referrer-Policy", "no-referrer");
  c.header("X-Robots-Tag", "noindex");
  return c.html(invitePage(usable ? invite : null), usable ? 200 : 404);
});
