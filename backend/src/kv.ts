/** Una entrada de `kv`. `fresh` es false si ya caducó (se devuelve igual, por si hace falta tirar de ella). */
export type KvEntry = { value: string; fresh: boolean };

export async function kvGet(db: D1Database, key: string, now = Date.now()): Promise<KvEntry | null> {
  const row = await db
    .prepare("SELECT value, expires_at FROM kv WHERE key = ?")
    .bind(key)
    .first<{ value: string; expires_at: number | null }>();
  if (!row) return null;
  return { value: row.value, fresh: row.expires_at === null || row.expires_at > now };
}

export function kvSetStatement(db: D1Database, key: string, value: string, expiresAt: number | null = null) {
  return db
    .prepare(
      `INSERT INTO kv (key, value, expires_at) VALUES (?1, ?2, ?3)
       ON CONFLICT(key) DO UPDATE SET value = ?2, expires_at = ?3`,
    )
    .bind(key, value, expiresAt);
}

export async function kvSet(db: D1Database, key: string, value: string, expiresAt: number | null = null) {
  await kvSetStatement(db, key, value, expiresAt).run();
}
