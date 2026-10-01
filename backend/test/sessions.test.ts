import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { sha256Hex } from "../src/auth/crypto";
import { api, register } from "./helpers";

const HOUR_MS = 60 * 60 * 1000;

describe("sesiones", () => {
  it("sin cabecera, con basura o con otro esquema: 401 unauthorized", async () => {
    expect((await api("/me")).body.error.code).toBe("unauthorized");
    expect((await api("/me", { token: "no-existe" })).status).toBe(401);
    const { token } = await register();
    const res = await exports.default.fetch("https://api.test/me", { headers: { authorization: `Basic ${token}` } });
    expect(res.status).toBe(401);
  });

  it("en la base solo está el hash del token", async () => {
    const { token } = await register();
    const row = await env.DB.prepare("SELECT token_hash FROM sessions").first<{ token_hash: string }>();
    expect(row!.token_hash).toBe(await sha256Hex(token));
  });

  it("caduca a los 180 días: 401 session_expired", async () => {
    const { token } = await register();
    await env.DB.prepare("UPDATE sessions SET expires_at = ?").bind(new Date(Date.now() - 1000).toISOString()).run();
    const res = await api("/me", { token });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("session_expired");
  });

  it("si se usa tras más de una hora, renueva last_seen y alarga la caducidad", async () => {
    const { token } = await register();
    const old = new Date(Date.now() - 2 * HOUR_MS).toISOString();
    await env.DB.prepare("UPDATE sessions SET last_seen_at = ?, expires_at = ?")
      .bind(old, new Date(Date.now() + 10 * 24 * HOUR_MS).toISOString())
      .run();
    await api("/me", { token });
    const row = await env.DB.prepare("SELECT last_seen_at, expires_at FROM sessions").first<{
      last_seen_at: string;
      expires_at: string;
    }>();
    expect(Date.parse(row!.last_seen_at)).toBeGreaterThan(Date.now() - 60_000);
    expect(Date.parse(row!.expires_at)).toBeGreaterThan(Date.now() + 179 * 24 * HOUR_MS);
  });

  it("si se usa antes de una hora, no escribe nada", async () => {
    const { token } = await register();
    const before = await env.DB.prepare("SELECT last_seen_at FROM sessions").first<{ last_seen_at: string }>();
    await api("/me", { token });
    const after = await env.DB.prepare("SELECT last_seen_at FROM sessions").first<{ last_seen_at: string }>();
    expect(after!.last_seen_at).toBe(before!.last_seen_at);
  });

  it("logout revoca solo esa sesión", async () => {
    const { token } = await register("kevin", "secreto123");
    const other = await register("raul", "secreto123");
    expect((await api("/auth/logout", { method: "POST", token })).status).toBe(204);
    expect((await api("/me", { token })).status).toBe(401);
    expect((await api("/me", { token: other.token })).status).toBe(200);
  });

  it("si suspenden la cuenta, las sesiones abiertas dan 403", async () => {
    const { token } = await register();
    await env.DB.prepare("UPDATE users SET status = 'suspended'").run();
    const res = await api("/me", { token });
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("account_suspended");
  });
});

