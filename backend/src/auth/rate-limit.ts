import { errors } from "../http/errors";

/** Ventana fija: como mucho `max` intentos por `key` cada `windowMinutes`. */
export type Limit = { key: string; max: number; windowMinutes: number };

const MINUTE_MS = 60 * 1000;

function windowFloor(now: Date, limit: Limit) {
  return new Date(now.getTime() - limit.windowMinutes * MINUTE_MS).toISOString();
}

/** Lanza 429 (con segundos de espera) si alguna de las claves llegó a su máximo. */
export async function assertNotLocked(db: D1Database, limits: Limit[], now: Date) {
  const rows = await db
    .prepare(
      `SELECT key, window_start, count FROM login_attempts WHERE key IN (${limits.map(() => "?").join(", ")})`,
    )
    .bind(...limits.map((l) => l.key))
    .all<{ key: string; window_start: string; count: number }>();

  let retryAfterMs = 0;
  for (const row of rows.results) {
    const limit = limits.find((l) => l.key === row.key)!;
    if (row.window_start > windowFloor(now, limit) && row.count >= limit.max) {
      const endsAt = Date.parse(row.window_start) + limit.windowMinutes * MINUTE_MS;
      retryAfterMs = Math.max(retryAfterMs, endsAt - now.getTime());
    }
  }
  if (retryAfterMs > 0) throw errors.tooManyAttempts(Math.ceil(retryAfterMs / 1000));
}

/** Suma un intento a cada clave; si su ventana ya pasó, empieza una nueva. */
export async function recordAttempt(db: D1Database, limits: Limit[], now: Date) {
  const at = now.toISOString();
  await db.batch(
    limits.map((l) =>
      db
        .prepare(
          `INSERT INTO login_attempts (key, window_start, count) VALUES (?1, ?2, 1)
           ON CONFLICT(key) DO UPDATE SET
             count = CASE WHEN window_start <= ?3 THEN 1 ELSE count + 1 END,
             window_start = CASE WHEN window_start <= ?3 THEN ?2 ELSE window_start END`,
        )
        .bind(l.key, at, windowFloor(now, l)),
    ),
  );
}

export async function clearAttempts(db: D1Database, keys: string[]) {
  await db.batch(keys.map((k) => db.prepare("DELETE FROM login_attempts WHERE key = ?").bind(k)));
}

// En Cuba mucha gente sale a internet por la misma IP (CGNAT de ETECSA): los límites por IP son
// altos a propósito, y el freno real es el límite por usuario.
export const authLimits = {
  register: (ip: string): Limit[] => [{ key: `register-ip:${ip}`, max: 30, windowMinutes: 60 }],
  login: (username: string, ip: string): Limit[] => [
    { key: `login-user:${username}`, max: 10, windowMinutes: 15 },
    { key: `login-ip:${ip}`, max: 100, windowMinutes: 15 },
  ],
  recover: (username: string, ip: string): Limit[] => [
    { key: `recover-user:${username}`, max: 5, windowMinutes: 15 },
    { key: `recover-ip:${ip}`, max: 100, windowMinutes: 15 },
  ],
};
