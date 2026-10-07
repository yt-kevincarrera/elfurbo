import { clubSettings } from "../clubs/model";
import type { SyncEntity } from "./changes";

type Row = Record<string, unknown>;

/** Cómo se lee cada entidad para el pull: tabla, columnas y forma en JSON (camelCase). */
type EntityDef = {
  table: string;
  /** Columna que filtra por servidor. */
  clubColumn: string;
  keyColumn: string;
  columns: string;
  toJson: (row: Row) => Record<string, unknown>;
};

export const ENTITIES: Record<SyncEntity, EntityDef> = {
  club: {
    table: "clubs",
    clubColumn: "id",
    keyColumn: "id",
    columns: "id, name, description, status, settings, kind, visibility, official, province, city, color, host_club_id, delisted",
    toJson: (r) => ({
      id: r.id,
      name: r.name,
      description: r.description,
      status: r.status,
      settings: clubSettings(String(r.settings)),
      kind: r.kind,
      visibility: r.visibility,
      official: r.official === 1,
      province: r.province,
      city: r.city,
      color: r.color,
      hostClubId: r.host_club_id,
      delisted: r.delisted === 1,
    }),
  },
  member: {
    table: "members",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, user_id, role, status, display_name, nickname, claimed_at",
    toJson: (r) => ({
      id: r.id,
      userId: r.user_id,
      role: r.role,
      status: r.status,
      displayName: r.display_name,
      nickname: r.nickname,
      claimedAt: r.claimed_at,
    }),
  },
  season: {
    table: "seasons",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, name, start_date, is_active, is_closed",
    toJson: (r) => ({
      id: r.id,
      name: r.name,
      startDate: r.start_date,
      isActive: r.is_active === 1,
      isClosed: r.is_closed === 1,
    }),
  },
  matchday: {
    table: "matchdays",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, season_id, starts_at, duration_minutes, place, notes, status, teams, created_by",
    toJson: (r) => ({
      id: r.id,
      seasonId: r.season_id,
      startsAt: r.starts_at,
      durationMinutes: r.duration_minutes,
      place: r.place,
      notes: r.notes,
      status: r.status,
      teams: r.teams === null ? null : JSON.parse(String(r.teams)),
      createdBy: r.created_by,
    }),
  },
  attendance: {
    table: "attendance",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, matchday_id, member_id, intent, played, played_set_by",
    toJson: (r) => ({
      id: r.id,
      matchdayId: r.matchday_id,
      memberId: r.member_id,
      intent: r.intent,
      played: r.played === null ? null : r.played === 1,
      playedSetBy: r.played_set_by,
    }),
  },
  report: {
    table: "reports",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, matchday_id, member_id, goals, assists, note, loaded_by, decision, corrected_by, updated_at",
    toJson: (r) => ({
      id: r.id,
      matchdayId: r.matchday_id,
      memberId: r.member_id,
      goals: r.goals,
      assists: r.assists,
      note: r.note,
      loadedBy: r.loaded_by,
      decision: r.decision,
      correctedBy: r.corrected_by,
      updatedAt: r.updated_at,
    }),
  },
  confirmation: {
    table: "report_confirmations",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, matchday_id, member_id, confirmer_id",
    toJson: (r) => ({ id: r.id, matchdayId: r.matchday_id, memberId: r.member_id, confirmerId: r.confirmer_id }),
  },
  vote: {
    table: "mvp_votes",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, matchday_id, voter_id, voted_for",
    toJson: (r) => ({ id: r.id, matchdayId: r.matchday_id, voterId: r.voter_id, votedFor: r.voted_for }),
  },
};

export const ENTITY_NAMES = Object.keys(ENTITIES) as SyncEntity[];

/** D1 admite como mucho 100 parámetros por sentencia. */
const CHUNK = 90;

/** Las filas actuales de `keys` (o de todo el servidor si `keys` es null). */
export async function readRows(db: D1Database, clubId: string, entity: SyncEntity, keys: string[] | null) {
  const def = ENTITIES[entity];
  const base = `SELECT ${def.columns} FROM ${def.table} WHERE ${def.clubColumn} = ?`;
  if (keys === null) {
    const { results } = await db.prepare(base).bind(clubId).all<Row>();
    return results.map(def.toJson);
  }
  const rows: Record<string, unknown>[] = [];
  for (let i = 0; i < keys.length; i += CHUNK) {
    const chunk = keys.slice(i, i + CHUNK);
    const { results } = await db
      .prepare(`${base} AND ${def.keyColumn} IN (${chunk.map(() => "?").join(", ")})`)
      .bind(clubId, ...chunk)
      .all<Row>();
    rows.push(...results.map(def.toJson));
  }
  return rows;
}
