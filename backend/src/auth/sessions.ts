import { randomToken, sha256Hex } from "./crypto";

const SESSION_DAYS = 180;
const DAY_MS = 24 * 60 * 60 * 1000;

function expiresFrom(now: Date) {
  return new Date(now.getTime() + SESSION_DAYS * DAY_MS).toISOString();
}

/** Prepara una sesión nueva. Se devuelve la sentencia para poder meterla en un `batch`. */
export async function newSession(db: D1Database, userId: string, deviceLabel: string | null, now: Date) {
  const token = randomToken();
  const at = now.toISOString();
  const statement = db
    .prepare(
      "INSERT INTO sessions (id, user_id, token_hash, device_label, created_at, last_seen_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(crypto.randomUUID(), userId, await sha256Hex(token), deviceLabel, at, at, expiresFrom(now));
  return { token, statement };
}
