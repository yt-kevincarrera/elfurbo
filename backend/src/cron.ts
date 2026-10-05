import { kvGet, kvSetStatement } from "./kv";
import type { Env } from "./types";

const DAY_MS = 24 * 60 * 60 * 1000;

/** Hasta dónde (id de `changes`) se purgó. Un cursor por debajo recibe una foto completa. */
export const PURGED_THROUGH_KEY = "sync.purgedThrough";

/** A qué hora UTC se purga (las 4 de la madrugada en Cuba). */
export const PURGE_HOUR_UTC = 8;

/** Cuánto se guarda cada cosa. */
export const RETENTION = {
  changes: 90 * DAY_MS, // un teléfono sin abrir la app más tiempo recibe la foto completa
  appliedCommands: 30 * DAY_MS, // un reintento posterior ya no se reconoce como duplicado
  expiredSessions: 7 * DAY_MS,
  loginAttempts: 7 * DAY_MS,
  recoveryCodes: 30 * DAY_MS,
};

/** El cron de cada hora (`0 * * * *`). */
export async function scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext) {
  ctx.waitUntil(hourly(env, new Date(controller.scheduledTime)));
}

export async function hourly(env: Env, now: Date) {
  if (now.getUTCHours() === PURGE_HOUR_UTC) await purge(env.DB, now);
}

const before = (now: Date, ms: number) => new Date(now.getTime() - ms).toISOString();

/** Borra lo viejo de las tablas que solo crecen. Repetirla no hace daño. */
export async function purge(db: D1Database, now: Date) {
  const last = await db
    .prepare("SELECT MAX(id) AS id FROM changes WHERE at < ?")
    .bind(before(now, RETENTION.changes))
    .first<{ id: number | null }>();
  const through = last?.id ?? 0;
  const previous = Number((await kvGet(db, PURGED_THROUGH_KEY))?.value ?? 0);
  const statements: D1PreparedStatement[] = [];
  if (through > previous) {
    // La marca y el borrado van juntos: un pull nunca ve el hueco sin la marca.
    statements.push(
      kvSetStatement(db, PURGED_THROUGH_KEY, String(through)),
      db.prepare("DELETE FROM changes WHERE id <= ?").bind(through),
    );
  }
  statements.push(
    db.prepare("DELETE FROM applied_commands WHERE at < ?").bind(before(now, RETENTION.appliedCommands)),
    db.prepare("DELETE FROM sessions WHERE expires_at < ?").bind(before(now, RETENTION.expiredSessions)),
    db.prepare("DELETE FROM login_attempts WHERE window_start < ?").bind(before(now, RETENTION.loginAttempts)),
    db
      .prepare("DELETE FROM recovery_codes WHERE expires_at < ? OR used_at < ?")
      .bind(before(now, RETENTION.recoveryCodes), before(now, RETENTION.recoveryCodes)),
  );
  await db.batch(statements);
}
