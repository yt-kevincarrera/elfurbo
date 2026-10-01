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

function upsertAttempt(db: D1Database, limit: Limit, now: Date) {
  return db
    .prepare(
      `INSERT INTO login_attempts (key, window_start, count) VALUES (?1, ?2, 1)
       ON CONFLICT(key) DO UPDATE SET
         count = CASE WHEN window_start <= ?3 THEN 1 ELSE count + 1 END,
         window_start = CASE WHEN window_start <= ?3 THEN ?2 ELSE window_start END
       RETURNING count, window_start`,
    )
    .bind(limit.key, now.toISOString(), windowFloor(now, limit));
}

/** Suma un intento a cada clave; si su ventana ya pasó, empieza una nueva. */
export async function recordAttempt(db: D1Database, limits: Limit[], now: Date) {
  await db.batch(limits.map((l) => upsertAttempt(db, l, now)));
}

/**
 * Cuenta el intento ANTES de hacerlo, en una sola sentencia atómica, y lanza 429 si con él se
 * pasa del máximo. Con "comprobar y luego sumar", N peticiones en paralelo (cada una en una
 * máquina de Cloudflare distinta) verían todas el contador bajo y se saltarían el bloqueo.
 */
export async function consumeAttempt(db: D1Database, limit: Limit, now: Date) {
  const row = (await upsertAttempt(db, limit, now).first<{ count: number; window_start: string }>())!;
  if (row.count > limit.max) {
    const endsAt = Date.parse(row.window_start) + limit.windowMinutes * MINUTE_MS;
    throw errors.tooManyAttempts(Math.max(1, Math.ceil((endsAt - now.getTime()) / 1000)));
  }
}

export async function clearAttempts(db: D1Database, keys: string[]) {
  await db.batch(keys.map((k) => db.prepare("DELETE FROM login_attempts WHERE key = ?").bind(k)));
}

// En Cuba mucha gente sale a internet por la misma IP (CGNAT de ETECSA): los límites por IP son
// altos a propósito y solo cuentan fallos contra usuarios que existen (si no, cualquiera inventando
// nombres dejaría sin entrar a toda la IP). El freno real es el límite por usuario. El de registro
// es alto porque en el corte a 1.0 se registra todo el grupo la misma noche.
export const authLimits = {
  register: (ip: string): Limit[] => [{ key: `register-ip:${ip}`, max: 200, windowMinutes: 60 }],
  login: (username: string, ip: string): [user: Limit, ip: Limit] => [
    { key: `login-user:${username}`, max: 10, windowMinutes: 15 },
    { key: `login-ip:${ip}`, max: 100, windowMinutes: 15 },
  ],
  recover: (username: string, ip: string): [user: Limit, ip: Limit] => [
    { key: `recover-user:${username}`, max: 5, windowMinutes: 15 },
    { key: `recover-ip:${ip}`, max: 100, windowMinutes: 15 },
  ],
};
