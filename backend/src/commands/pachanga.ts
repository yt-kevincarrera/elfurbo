import { z } from "zod";
import { errors } from "../http/errors";
import { isClosed, isPlayed, type MatchdayStatus } from "../rules/matchday";
import type { SyncEntity } from "../sync/changes";
import type { CommandContext } from "../sync/command";

/** Lo que los comandos necesitan saber de una jornada (una sola consulta, con su temporada). */
export type Matchday = {
  id: string;
  seasonId: string;
  startsAt: string;
  durationMinutes: number;
  status: MatchdayStatus;
  createdBy: string;
  seasonClosed: boolean;
};

export const matchdayId = z.string().min(1).max(64);
export const memberId = z.string().min(1).max(64);
export const goalsOrAssists = z.number().int().min(0).max(30);

export const key = (...parts: string[]) => parts.join(":");

export async function findMatchday(ctx: CommandContext, id: string): Promise<Matchday> {
  const row = await ctx.db
    .prepare(
      `SELECT md.id, md.season_id, md.starts_at, md.duration_minutes, md.status, md.created_by, s.is_closed
         FROM matchdays md JOIN seasons s ON s.id = md.season_id
        WHERE md.id = ? AND md.club_id = ?`,
    )
    .bind(id, ctx.club.id)
    .first<{
      id: string;
      season_id: string;
      starts_at: string;
      duration_minutes: number;
      status: MatchdayStatus;
      created_by: string;
      is_closed: number;
    }>();
  if (!row) throw errors.notFound();
  return {
    id: row.id,
    seasonId: row.season_id,
    startsAt: row.starts_at,
    durationMinutes: row.duration_minutes,
    status: row.status,
    createdBy: row.created_by,
    seasonClosed: row.is_closed === 1,
  };
}

/**
 * Cerrada = no acepta cambios de nadie (el staff la reabre para corregir). El plazo se mide con la
 * hora del teléfono (acotada): un reporte hecho a tiempo sin señal no se pierde. Un cierre a mano
 * se ve en el estado actual, así que gana siempre.
 */
export function assertOpen(ctx: CommandContext, md: Matchday) {
  if (isClosed(md, ctx.clientAt, ctx.club.settings.closeAfterHours)) throw errors.matchdayClosed();
}

/** "Ya se jugó" con la hora del servidor: si terminó de verdad, vale aunque el teléfono se adelantara. */
export function assertPlayed(ctx: CommandContext, md: Matchday) {
  if (!isPlayed(md, ctx.now)) throw errors.matchdayNotPlayed();
}

/** Miembros activos de este servidor (con o sin cuenta). Lanza 400 si alguno no lo es. */
export async function assertActiveMembers(ctx: CommandContext, ids: string[], field: string) {
  const unique = [...new Set(ids)];
  if (unique.length === 0) return;
  const { results } = await ctx.db
    .prepare(
      `SELECT id FROM members WHERE club_id = ? AND status = 'active' AND id IN (${unique.map(() => "?").join(", ")})`,
    )
    .bind(ctx.club.id, ...unique)
    .all<{ id: string }>();
  if (results.length !== unique.length) {
    throw errors.invalidInput({ [field]: ["Alguno no es miembro activo de este servidor"] });
  }
}

/**
 * Filas de `changes` para todo lo que cuelga de una jornada en `table`, calculadas en SQL (sin leer
 * las filas). Van en el batch antes de borrarlas o moverlas.
 */
export function childChanges(
  ctx: CommandContext,
  table: string,
  entity: SyncEntity,
  op: "upsert" | "delete",
  where: string,
  ...binds: unknown[]
) {
  return ctx.db
    .prepare(`INSERT INTO changes (club_id, entity, entity_key, op, at) SELECT club_id, ?, id, ?, ? FROM ${table} WHERE ${where}`)
    .bind(entity, op, ctx.now.toISOString(), ...binds);
}

/** Las tablas que cuelgan de una jornada, con su entidad de sync. */
export const CHILDREN: { table: string; entity: SyncEntity }[] = [
  { table: "report_confirmations", entity: "confirmation" },
  { table: "mvp_votes", entity: "vote" },
  { table: "reports", entity: "report" },
  { table: "attendance", entity: "attendance" },
];
