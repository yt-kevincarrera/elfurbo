import { env } from "cloudflare:workers";
import { expect } from "vitest";
import type { Role } from "../src/authz";
import { api, register, type Registered } from "./helpers";

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

export type ActiveClub = { clubId: string; owner: Registered; admin: Registered };

/** Un servidor aprobado de punta a punta por la API: dueño + superadmin. */
export async function activeClub(ownerUsername = "dueno", name = "Pachanga del sábado"): Promise<ActiveClub> {
  const owner = await register(ownerUsername, "secreto123", "Dueño");
  const admin = await superadmin(`super.${ownerUsername}`);
  const clubId = await requestClub(owner.token, name);
  const res = await api(`/admin/clubs/${clubId}/approve`, { method: "POST", token: admin.token });
  expect(res.status).toBe(200);
  return { clubId, owner, admin };
}

/** Mete a un usuario nuevo como miembro con `role`, directo en la base (sin invitación). */
export async function addMember(clubId: string, username: string, role: Exclude<Role, "guest">) {
  const reg = await register(username, "secreto123", username);
  const memberId = crypto.randomUUID();
  const at = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(memberId, clubId, reg.user.id, role, username, at, at)
    .run();
  return { ...reg, memberId };
}

/** Un jugador sin cuenta (en el PR3 los creará el comando `member.createGuest`). */
export async function addGuest(clubId: string, displayName = "Yoandry") {
  const memberId = crypto.randomUUID();
  const at = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, NULL, 'guest', ?, ?, ?)",
  )
    .bind(memberId, clubId, displayName, at, at)
    .run();
  return memberId;
}

export async function ownerMemberId(clubId: string) {
  const row = await env.DB.prepare("SELECT id FROM members WHERE club_id = ? AND role = 'owner'")
    .bind(clubId)
    .first<{ id: string }>();
  return row!.id;
}

export async function auditActions(clubId: string | null) {
  const { results } = await env.DB.prepare(
    "SELECT action FROM audit_log WHERE club_id IS ? ORDER BY id",
  )
    .bind(clubId)
    .all<{ action: string }>();
  return results.map((r) => r.action);
}
