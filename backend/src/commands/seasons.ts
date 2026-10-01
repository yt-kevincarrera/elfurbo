import { z } from "zod";
import { canManageSeasons } from "../authz";
import { errors } from "../http/errors";
import { remove, upsert, type Touch } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";

const name = z.string().trim().min(1, { error: "Escribe un nombre" }).max(40);
const startDate = z.iso.date({ error: "Fecha no válida (AAAA-MM-DD)" });
const seasonId = z.string().min(1).max(64);

type SeasonRow = { id: string; is_active: number; is_closed: number };

async function findSeason(ctx: CommandContext, id: string) {
  const row = await ctx.db
    .prepare("SELECT id, is_active, is_closed FROM seasons WHERE id = ? AND club_id = ?")
    .bind(id, ctx.club.id)
    .first<SeasonRow>();
  if (!row) throw errors.notFound();
  return row;
}

function assertCanManage(ctx: CommandContext) {
  if (!canManageSeasons(ctx.member.role)) throw errors.forbidden();
}

/** Desactiva la temporada activa (si hay otra) antes de activar `newActiveId`. */
async function deactivateCurrent(ctx: CommandContext, newActiveId: string) {
  const current = await ctx.db
    .prepare("SELECT id FROM seasons WHERE club_id = ? AND is_active = 1 AND id <> ?")
    .bind(ctx.club.id, newActiveId)
    .first<{ id: string }>();
  const statements = current
    ? [ctx.db.prepare("UPDATE seasons SET is_active = 0, updated_at = ? WHERE id = ?").bind(ctx.now.toISOString(), current.id)]
    : [];
  const touched: Touch[] = current ? [upsert("season", current.id)] : [];
  return { statements, touched };
}

export const createSeason = command(
  z.object({ id: z.uuid(), name, startDate, activate: z.boolean().default(false) }),
  async (ctx, p) => {
    assertCanManage(ctx);
    const off = p.activate ? await deactivateCurrent(ctx, p.id) : { statements: [], touched: [] };
    const at = ctx.now.toISOString();
    return {
      statements: [
        ...off.statements,
        ctx.db
          .prepare(
            "INSERT INTO seasons (id, club_id, name, start_date, is_active, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
          )
          .bind(p.id, ctx.club.id, p.name, p.startDate, p.activate ? 1 : 0, at, at),
      ],
      touched: [...off.touched, upsert("season", p.id)],
    };
  },
);

export const updateSeason = command(
  z
    .object({ seasonId, name: name.optional(), startDate: startDate.optional() })
    .refine((p) => p.name !== undefined || p.startDate !== undefined, { error: "Nada que cambiar" }),
  async (ctx, p) => {
    assertCanManage(ctx);
    const s = await findSeason(ctx, p.seasonId);
    return {
      statements: [
        ctx.db
          .prepare(
            "UPDATE seasons SET name = COALESCE(?, name), start_date = COALESCE(?, start_date), updated_at = ? WHERE id = ?",
          )
          .bind(p.name ?? null, p.startDate ?? null, ctx.now.toISOString(), s.id),
      ],
      touched: [upsert("season", s.id)],
    };
  },
);

export const activateSeason = command(z.object({ seasonId }), async (ctx, p) => {
  assertCanManage(ctx);
  const s = await findSeason(ctx, p.seasonId);
  if (s.is_closed === 1) throw errors.invalidState("Una temporada cerrada no puede ser la activa");
  const off = await deactivateCurrent(ctx, s.id);
  return {
    statements: [
      ...off.statements,
      ctx.db.prepare("UPDATE seasons SET is_active = 1, updated_at = ? WHERE id = ?").bind(ctx.now.toISOString(), s.id),
    ],
    touched: [...off.touched, upsert("season", s.id)],
  };
});

/** Cerrar deja de ser la activa (una cerrada no puede serlo). Reabrir no la vuelve a activar. */
export const setSeasonClosed = command(z.object({ seasonId, closed: z.boolean() }), async (ctx, p) => {
  assertCanManage(ctx);
  const s = await findSeason(ctx, p.seasonId);
  return {
    statements: [
      ctx.db
        .prepare(
          `UPDATE seasons SET is_closed = ?, is_active = CASE WHEN ? = 1 THEN 0 ELSE is_active END, updated_at = ?
            WHERE id = ?`,
        )
        .bind(p.closed ? 1 : 0, p.closed ? 1 : 0, ctx.now.toISOString(), s.id),
    ],
    touched: [upsert("season", s.id)],
  };
});

/** Solo si no tiene jornadas (si no, primero hay que moverlas o borrarlas). */
export const deleteSeason = command(z.object({ seasonId }), async (ctx, p) => {
  assertCanManage(ctx);
  const s = await findSeason(ctx, p.seasonId);
  const used = await ctx.db.prepare("SELECT 1 FROM matchdays WHERE season_id = ? LIMIT 1").bind(s.id).first();
  if (used) throw errors.seasonHasMatchdays();
  return {
    statements: [ctx.db.prepare("DELETE FROM seasons WHERE id = ?").bind(s.id)],
    touched: [remove("season", s.id)],
    audit: [{ action: "season.delete", entity: "season", entityKey: s.id }],
  };
});
