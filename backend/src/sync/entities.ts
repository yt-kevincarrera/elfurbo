import { DEFAULT_SETTINGS } from "../clubs/model";
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
    columns: "id, name, description, status, settings",
    toJson: (r) => ({
      id: r.id,
      name: r.name,
      description: r.description,
      status: r.status,
      settings: { ...DEFAULT_SETTINGS, ...JSON.parse(String(r.settings)) },
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
