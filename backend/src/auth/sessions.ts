import { errors } from "../http/errors";
import { randomToken, sha256Hex } from "./crypto";
import type { PublicUser, UserStatus } from "./users";

const SESSION_DAYS = 180;
const DAY_MS = 24 * 60 * 60 * 1000;
/** Solo se reescribe `last_seen_at` si pasó más de esto: una escritura por hora, no por petición. */
const TOUCH_AFTER_MS = 60 * 60 * 1000;

export type AuthContext = { sessionId: string; user: PublicUser };

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

type SessionRow = {
  session_id: string;
  last_seen_at: string;
  expires_at: string;
  id: string;
  username: string;
  display_name: string;
  is_superadmin: number;
  status: UserStatus;
};

/** Valida un token. Lanza 401 si no existe o caducó, 403 si la cuenta está suspendida. */
export async function authenticate(db: D1Database, token: string, now: Date): Promise<AuthContext> {
  const row = await db
    .prepare(
      `SELECT s.id AS session_id, s.last_seen_at, s.expires_at,
              u.id, u.username, u.display_name, u.is_superadmin, u.status
         FROM sessions s JOIN users u ON u.id = s.user_id
        WHERE s.token_hash = ?`,
    )
    .bind(await sha256Hex(token))
    .first<SessionRow>();
  if (!row) throw errors.unauthorized();
  if (row.expires_at <= now.toISOString()) throw errors.sessionExpired();
  if (row.status === "suspended") throw errors.accountSuspended();

  if (now.getTime() - Date.parse(row.last_seen_at) > TOUCH_AFTER_MS) {
    await db
      .prepare("UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE id = ?")
      .bind(now.toISOString(), expiresFrom(now), row.session_id)
      .run();
  }

  return {
    sessionId: row.session_id,
    user: {
      id: row.id,
      username: row.username,
      displayName: row.display_name,
      isSuperadmin: row.is_superadmin === 1,
      status: row.status,
    },
  };
}

export function deleteSessionStatement(db: D1Database, sessionId: string) {
  return db.prepare("DELETE FROM sessions WHERE id = ?").bind(sessionId);
}

/** Borra todas las sesiones del usuario salvo, opcionalmente, una. */
export function deleteUserSessionsStatement(db: D1Database, userId: string, exceptSessionId?: string) {
  return exceptSessionId
    ? db.prepare("DELETE FROM sessions WHERE user_id = ? AND id <> ?").bind(userId, exceptSessionId)
    : db.prepare("DELETE FROM sessions WHERE user_id = ?").bind(userId);
}
