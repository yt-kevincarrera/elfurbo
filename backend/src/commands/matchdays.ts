import { z } from "zod";
import { canActForOthers, canCreateMatchday, canEditMatchday, canManageMatchday } from "../authz";
import { errors } from "../http/errors";
import { remove, upsert } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { assertActiveMembers, assertOpen, CHILDREN, childChanges, findMatchday, matchdayId, type Matchday } from "./pachanga";

const startsAt = z.iso.datetime({ offset: true }).transform((s) => new Date(s).toISOString());
const durationMinutes = z.number().int().min(30).max(600);
const place = z.string().trim().max(80).nullable();
const notes = z.string().trim().max(300).nullable();
const seasonId = z.string().min(1).max(64);

/** ¿Hay datos de alguien que no sea quien la creó? (asistencia, reportes o votos). */
async function hasOthersData(ctx: CommandContext, md: Matchday) {
  const row = await ctx.db
    .prepare(
      `SELECT EXISTS (SELECT 1 FROM attendance WHERE matchday_id = ?1 AND member_id <> ?2)
           OR EXISTS (SELECT 1 FROM reports WHERE matchday_id = ?1 AND member_id <> ?2)
           OR EXISTS (SELECT 1 FROM mvp_votes WHERE matchday_id = ?1 AND voter_id <> ?2) AS others`,
    )
    .bind(md.id, md.createdBy)
    .first<{ others: number }>();
  return row!.others === 1;
}

async function assertCanManage(ctx: CommandContext, md: Matchday) {
  const isCreator = md.createdBy === ctx.member.id;
  // La consulta solo hace falta para el player que la creó; el staff puede siempre.
  const others = ctx.member.role === "player" && isCreator ? await hasOthersData(ctx, md) : false;
  if (!canManageMatchday(ctx.member.role, { isCreator, hasOthersData: others })) throw errors.forbidden();
}

/** La temporada indicada (o la activa) tiene que existir en el servidor y no estar cerrada. */
async function resolveSeason(ctx: CommandContext, id: string | undefined) {
  const row = id
    ? await ctx.db
        .prepare("SELECT id, is_closed FROM seasons WHERE id = ? AND club_id = ?")
        .bind(id, ctx.club.id)
        .first<{ id: string; is_closed: number }>()
    : await ctx.db
        .prepare("SELECT id, is_closed FROM seasons WHERE club_id = ? AND is_active = 1")
        .bind(ctx.club.id)
        .first<{ id: string; is_closed: number }>();
  if (!row) throw id ? errors.notFound() : errors.noActiveSeason();
  if (row.is_closed === 1) throw errors.seasonClosed();
  return row.id;
}

/** Una jornada. El id lo pone la app; repetir cada semana = un comando por fecha. */
export const createMatchday = command(
  z.object({
    id: z.uuid(),
    startsAt,
    durationMinutes: durationMinutes.default(120),
    place: place.optional(),
    notes: notes.optional(),
    seasonId: seasonId.optional(),
  }),
  async (ctx, p) => {
    if (!canCreateMatchday(ctx.member.role, ctx.club.settings.matchdayCreators)) throw errors.forbidden();
    const season = await resolveSeason(ctx, p.seasonId);
    const at = ctx.now.toISOString();
    return {
      statements: [
        ctx.db
          .prepare(
            `INSERT INTO matchdays (id, club_id, season_id, starts_at, duration_minutes, place, notes, created_by, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(p.id, ctx.club.id, season, p.startsAt, p.durationMinutes, p.place ?? null, p.notes ?? null, ctx.member.id, at, at),
      ],
      touched: [upsert("matchday", p.id)],
    };
  },
);

/** Fecha, duración, lugar, notas o temporada. Lo que no venga se queda como está; `null` borra. */
export const updateMatchday = command(
  z
    .object({
      matchdayId,
      startsAt: startsAt.optional(),
      durationMinutes: durationMinutes.optional(),
      place: place.optional(),
      notes: notes.optional(),
      seasonId: seasonId.optional(),
    })
    .refine((p) => Object.keys(p).length > 1, { error: "Nada que cambiar" }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    if (!canEditMatchday(ctx.member.role, { isCreator: md.createdBy === ctx.member.id })) throw errors.forbidden();
    const season = p.seasonId === undefined ? md.seasonId : await resolveSeason(ctx, p.seasonId);
    return {
      statements: [
        ctx.db
          .prepare(
            `UPDATE matchdays SET starts_at = ?, duration_minutes = ?,
                    place = CASE WHEN ? THEN ? ELSE place END,
                    notes = CASE WHEN ? THEN ? ELSE notes END,
                    season_id = ?, updated_at = ?
              WHERE id = ?`,
          )
          .bind(
            p.startsAt ?? md.startsAt,
            p.durationMinutes ?? md.durationMinutes,
            p.place !== undefined ? 1 : 0,
            p.place ?? null,
            p.notes !== undefined ? 1 : 0,
            p.notes ?? null,
            season,
            ctx.now.toISOString(),
            md.id,
          ),
      ],
      touched: [upsert("matchday", md.id)],
    };
  },
);

/** Cancelar, reactivar, cerrar a mano o reabrir. */
export const setMatchdayStatus = command(
  z.object({ matchdayId, status: z.enum(["scheduled", "cancelled", "closed", "reopened"]) }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    await assertCanManage(ctx, md);
    if (md.seasonClosed) throw errors.seasonClosed();
    return {
      statements: [
        ctx.db.prepare("UPDATE matchdays SET status = ?, updated_at = ? WHERE id = ?").bind(p.status, ctx.now.toISOString(), md.id),
      ],
      touched: [upsert("matchday", md.id)],
      audit: [{ action: "matchday.setStatus", entity: "matchday", entityKey: md.id, summary: { from: md.status, to: p.status } }],
    };
  },
);

/** Borra la jornada y todo lo que cuelga de ella (asistencia, reportes, confirmaciones, votos). */
export const deleteMatchday = command(z.object({ matchdayId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  await assertCanManage(ctx, md);
  const statements: D1PreparedStatement[] = [];
  for (const { table, entity } of CHILDREN) {
    statements.push(childChanges(ctx, table, entity, "delete", "matchday_id = ?", md.id));
    statements.push(ctx.db.prepare(`DELETE FROM ${table} WHERE matchday_id = ?`).bind(md.id));
  }
  statements.push(ctx.db.prepare("DELETE FROM matchdays WHERE id = ?").bind(md.id));
  return {
    statements,
    touched: [remove("matchday", md.id)],
    audit: [{ action: "matchday.delete", entity: "matchday", entityKey: md.id }],
  };
});

/** Equipos (opcional). `null` los quita. Solo miembros activos del servidor. */
export const saveTeams = command(
  z.object({
    matchdayId,
    teams: z.object({ a: z.array(z.string().min(1).max(64)).max(40), b: z.array(z.string().min(1).max(64)).max(40) }).nullable(),
  }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    if (p.teams) await assertActiveMembers(ctx, [...p.teams.a, ...p.teams.b], "teams");
    return {
      statements: [
        ctx.db
          .prepare("UPDATE matchdays SET teams = ?, updated_at = ? WHERE id = ?")
          .bind(p.teams ? JSON.stringify(p.teams) : null, ctx.now.toISOString(), md.id),
      ],
      touched: [upsert("matchday", md.id)],
    };
  },
);
