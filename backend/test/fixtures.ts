import { env } from "cloudflare:workers";
import { expect } from "vitest";
import { api, register } from "./helpers";

/** Registra un usuario y lo marca como superadmin (en producción se hace con `wrangler d1 execute`). */
export async function superadmin(username = "superadmin") {
  const reg = await register(username, "secreto123", "Súper");
  await env.DB.prepare("UPDATE users SET is_superadmin = 1 WHERE id = ?").bind(reg.user.id).run();
  return reg;
}

/** Pide un servidor con la API y devuelve su id. */
export async function requestClub(token: string, name = "Pachanga del sábado", extra: Record<string, unknown> = {}) {
  const res = await api("/clubs", { token, body: { name, ...extra } });
  expect(res.status).toBe(201);
  return res.body.club.id as string;
}

export async function auditActions(clubId: string | null) {
  const { results } = await env.DB.prepare(
    "SELECT action FROM audit_log WHERE club_id IS ? ORDER BY id",
  )
    .bind(clubId)
    .all<{ action: string }>();
  return results.map((r) => r.action);
}
