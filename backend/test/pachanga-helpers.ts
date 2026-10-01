import { env } from "cloudflare:workers";
import { expect } from "vitest";
import { addGuest, addMember } from "./fixtures";
import { apply, cmd } from "./sync-helpers";

export const hoursAgo = (h: number) => new Date(Date.now() - h * 3600_000).toISOString();

/**
 * Crea una jornada con un comando. Por defecto empezó hace 3 h y duró 2 (ya se jugó, sigue abierta).
 * `startsAt` en el futuro = todavía no se jugó.
 */
export async function matchday(token: string, clubId: string, extra: Record<string, unknown> = {}) {
  const id = crypto.randomUUID();
  await apply(token, cmd(clubId, "matchday.create", { id, startsAt: hoursAgo(3), durationMinutes: 120, ...extra }));
  return id;
}

/** Marca "jugué" a varios con el comando del propio jugador. */
export async function played(clubId: string, matchdayId: string, ...tokens: string[]) {
  for (const token of tokens) await apply(token, cmd(clubId, "attendance.setPlayed", { matchdayId, played: true }));
}

/** Un grupo típico: dueño, un admin, un anotador, dos jugadores y uno sin cuenta. */
export async function squad(clubId: string) {
  return {
    admin: await addMember(clubId, "jefe", "admin"),
    scorer: await addMember(clubId, "anotador", "scorer"),
    raul: await addMember(clubId, "raul", "player"),
    pepe: await addMember(clubId, "pepe", "player"),
    guest: await addGuest(clubId, "Yoandry"),
  };
}

export async function row(table: string, id: string) {
  return env.DB.prepare(`SELECT * FROM ${table} WHERE id = ?`).bind(id).first();
}

export async function count(table: string, where = "1", ...binds: unknown[]) {
  const r = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${where}`).bind(...binds).first<{ n: number }>();
  expect(r).not.toBeNull();
  return r!.n;
}
