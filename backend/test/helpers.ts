import { env, exports } from "cloudflare:workers";
import { expect } from "vitest";
import { normalizeCode, sha256Hex } from "../src/auth/crypto";

type ApiInit = { method?: string; body?: unknown; token?: string; ip?: string };

/** Llama al Worker como lo haría la app. `body` string se manda tal cual (para JSON roto). */
export async function api(path: string, init: ApiInit = {}) {
  const headers: Record<string, string> = {};
  if (init.body !== undefined) headers["content-type"] = "application/json";
  if (init.token) headers.authorization = `Bearer ${init.token}`;
  if (init.ip) headers["cf-connecting-ip"] = init.ip;
  const res = await exports.default.fetch(`https://api.test${path}`, {
    method: init.method ?? (init.body !== undefined ? "POST" : "GET"),
    headers,
    body:
      init.body === undefined ? undefined : typeof init.body === "string" ? init.body : JSON.stringify(init.body),
  });
  const text = await res.text();
  return { status: res.status, headers: res.headers, body: text ? JSON.parse(text) : null };
}

export type Registered = {
  token: string;
  user: { id: string; username: string; displayName: string; isSuperadmin: boolean; status: string };
};

export async function register(username = "kevin", password = "secreto123", displayName = "Kevin") {
  const res = await api("/auth/register", { body: { username, password, displayName } });
  expect(res.status).toBe(201);
  return res.body as Registered;
}

export async function login(username: string, password: string, ip?: string) {
  return api("/auth/login", { body: { username, password }, ip });
}

/** Inserta un código de recuperación como lo hará el PR2 (admin o superadmin). */
export async function insertRecoveryCode(
  userId: string,
  code: string,
  opts: { expiresAt?: string; usedAt?: string } = {},
) {
  await env.DB.prepare(
    "INSERT INTO recovery_codes (id, user_id, code_hash, created_by, expires_at, used_at) VALUES (?, ?, ?, ?, ?, ?)",
  )
    .bind(
      crypto.randomUUID(),
      userId,
      await sha256Hex(normalizeCode(code)),
      "superadmin-de-prueba",
      opts.expiresAt ?? new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      opts.usedAt ?? null,
    )
    .run();
}
