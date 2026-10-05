import { z } from "zod";
import type { PublicUser } from "../auth/users";
import type { SyncEntity } from "./changes";
import { PURGED_THROUGH_KEY } from "../cron";
import { kvGet } from "../kv";
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
 * Un cursor más viejo que la purga de `changes` (90 días) también recibe la foto completa.
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
    if (asked.length) {
      const { results: existing } = await db
        .prepare(`SELECT id FROM clubs WHERE id IN (${asked.map(() => "?").join(", ")})`)
        .bind(...asked)
        .all<{ id: string }>();
      for (const r of existing) allowed.add(r.id);
    }
  }

  // Los cursores son ids globales de `changes` (autoincrementales, no se reutilizan). `top` es el
  // último que existe: un servidor sin cambios nuevos avanza hasta ahí, así su cursor nunca se queda
  // por debajo de la purga solo por estar tranquilo (si no, recibiría una foto completa cada día).
  const purged = await purgedThrough(db);
  const top = Math.max(await lastChangeId(db), purged);
  const clubs: Record<string, ClubPull> = {};
  for (const clubId of allowed) {
    const cursor = cursors[clubId] ?? 0;
    // Cursor 0, uno de antes de la purga, o uno por delante del servidor (la base se restauró con
    // Time Travel): foto completa.
    const full = cursor === 0 || cursor < purged || cursor > top;
    clubs[clubId] = full ? await snapshot(db, clubId, top) : await incremental(db, clubId, cursor, top);
  }
  // Una purga que terminó mientras tanto pudo borrar cambios que un incremental ya no vio: esos,
  // otra vez como foto completa.
  const purgedNow = await purgedThrough(db);
  if (purgedNow > purged) {
    for (const clubId of allowed) {
      const cursor = cursors[clubId] ?? 0;
      if (!clubs[clubId]!.snapshot && cursor < purgedNow) {
        clubs[clubId] = await snapshot(db, clubId, Math.max(top, purgedNow));
      }
    }
  }
  const removed = Object.keys(cursors).filter((id) => !allowed.has(id));
  return { clubs, removed };
}

async function purgedThrough(db: D1Database) {
  return Number((await kvGet(db, PURGED_THROUGH_KEY))?.value ?? 0);
}

/** El último id de `changes` (de todos los servidores; es la clave primaria, cuesta una fila). */
async function lastChangeId(db: D1Database) {
  const row = await db.prepare("SELECT COALESCE(MAX(id), 0) AS id FROM changes").first<{ id: number }>();
  return row!.id;
}

async function snapshot(db: D1Database, clubId: string, top: number): Promise<ClubPull> {
  // El cursor se toma antes de leer: si algo cambia mientras tanto, llegará otra vez (es inocuo).
  const upserts: ClubPull["upserts"] = {};
  for (const entity of ENTITY_NAMES) upserts[entity] = await readRows(db, clubId, entity, null);
  return { cursor: top, hasMore: false, snapshot: true, upserts, deletes: {} };
}

async function incremental(db: D1Database, clubId: string, cursor: number, top: number): Promise<ClubPull> {
  const { results } = await db
    .prepare(
      `SELECT entity, entity_key, MAX(id) AS last FROM changes
        WHERE club_id = ? AND id > ? AND id <= ?
        GROUP BY entity, entity_key ORDER BY last LIMIT ?`,
    )
    .bind(clubId, cursor, top, PAGE + 1)
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
  // Sin más páginas, todo lo de este servidor hasta `top` ya está: el cursor llega hasta ahí.
  const newCursor = hasMore ? page[page.length - 1]!.last : top;
  return { cursor: newCursor, hasMore, snapshot: false, upserts, deletes };
}
