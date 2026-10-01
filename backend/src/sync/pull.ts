import { z } from "zod";
import type { PublicUser } from "../auth/users";
import type { SyncEntity } from "./changes";
import { ENTITY_NAMES, readRows } from "./entities";

export const pullSchema = z.object({
  cursors: z
    .record(z.string().min(1).max(64), z.number().int().min(0))
    .refine((c) => Object.keys(c).length <= 50, { error: "Demasiados servidores" }),
});

/** Cambios por servidor y respuesta. Con más, `hasMore` y la app vuelve a pedir. */
export const PAGE = 500;

type ClubPull = {
  cursor: number;
  hasMore: boolean;
  snapshot: boolean;
  upserts: Partial<Record<SyncEntity, Record<string, unknown>[]>>;
  deletes: Partial<Record<SyncEntity, string[]>>;
};

/**
 * Lo que cambió en cada servidor del usuario desde su cursor. Cursor 0 (o un servidor nuevo para la
 * app) = foto completa. Los servidores que la app tiene pero a los que ya no pertenece van en
 * `removed`, para que borre sus datos locales. El superadmin puede pedir cualquier servidor.
 */
export async function pull(db: D1Database, user: PublicUser, cursors: Record<string, number>) {
  const { results } = await db
    .prepare(
      `SELECT m.club_id FROM members m JOIN clubs c ON c.id = m.club_id
        WHERE m.user_id = ? AND m.status = 'active' AND c.status IN ('active', 'suspended')`,
    )
    .bind(user.id)
    .all<{ club_id: string }>();
  const allowed = new Set(results.map((r) => r.club_id));

  if (user.isSuperadmin) {
    const asked = Object.keys(cursors).filter((id) => !allowed.has(id));
    for (const id of asked) {
      const exists = await db.prepare("SELECT 1 FROM clubs WHERE id = ?").bind(id).first();
      if (exists) allowed.add(id);
    }
  }

  const clubs: Record<string, ClubPull> = {};
  for (const clubId of allowed) {
    const cursor = cursors[clubId] ?? 0;
    clubs[clubId] = cursor === 0 ? await snapshot(db, clubId) : await incremental(db, clubId, cursor);
  }
  const removed = Object.keys(cursors).filter((id) => !allowed.has(id));
  return { clubs, removed };
}

async function lastChangeId(db: D1Database, clubId: string) {
  const row = await db
    .prepare("SELECT COALESCE(MAX(id), 0) AS id FROM changes WHERE club_id = ?")
    .bind(clubId)
    .first<{ id: number }>();
  return row!.id;
}

async function snapshot(db: D1Database, clubId: string): Promise<ClubPull> {
  // El cursor se toma antes de leer: si algo cambia mientras tanto, llegará otra vez (es inocuo).
  const cursor = await lastChangeId(db, clubId);
  const upserts: ClubPull["upserts"] = {};
  for (const entity of ENTITY_NAMES) upserts[entity] = await readRows(db, clubId, entity, null);
  return { cursor, hasMore: false, snapshot: true, upserts, deletes: {} };
}

async function incremental(db: D1Database, clubId: string, cursor: number): Promise<ClubPull> {
  const { results } = await db
    .prepare(
      `SELECT entity, entity_key, MAX(id) AS last FROM changes
        WHERE club_id = ? AND id > ?
        GROUP BY entity, entity_key ORDER BY last LIMIT ?`,
    )
    .bind(clubId, cursor, PAGE + 1)
    .all<{ entity: SyncEntity; entity_key: string; last: number }>();
  const hasMore = results.length > PAGE;
  const page = results.slice(0, PAGE);

  const upserts: ClubPull["upserts"] = {};
  const deletes: ClubPull["deletes"] = {};
  for (const entity of ENTITY_NAMES) {
    const keys = page.filter((r) => r.entity === entity).map((r) => r.entity_key);
    if (keys.length === 0) continue;
    const rows = await readRows(db, clubId, entity, keys);
    const found = new Set(rows.map((r) => String(r.id)));
    if (rows.length) upserts[entity] = rows;
    const gone = keys.filter((k) => !found.has(k));
    if (gone.length) deletes[entity] = gone;
  }
  const newCursor = page.length ? page[page.length - 1]!.last : cursor;
  return { cursor: newCursor, hasMore, snapshot: false, upserts, deletes };
}
