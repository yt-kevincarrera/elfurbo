import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { sha256Hex } from "../src/auth/crypto";
import { api, register } from "./helpers";

describe("POST /auth/register", () => {
  it("crea la cuenta y una sesión para el token devuelto", async () => {
    const { token, user } = await register("kevin", "secreto123", "Kevin");
    expect(user).toMatchObject({ username: "kevin", displayName: "Kevin", isSuperadmin: false, status: "active" });
    const session = await env.DB.prepare("SELECT user_id FROM sessions WHERE token_hash = ?")
      .bind(await sha256Hex(token))
      .first<{ user_id: string }>();
    expect(session!.user_id).toBe(user.id);
    const me = await api("/me", { token });
    expect(me.status).toBe(200);
    expect(me.body.user.id).toBe(user.id);
  });

  it("guarda el hash, nunca la contraseña", async () => {
    await register("kevin", "secreto123");
    const row = await env.DB.prepare("SELECT password_hash FROM users WHERE username = 'kevin'").first<{
      password_hash: string;
    }>();
    expect(row!.password_hash).toMatch(/^pbkdf2_sha256\$/);
    expect(row!.password_hash).not.toContain("secreto123");
  });

  it("normaliza el usuario: espacios y mayúsculas no cuentan", async () => {
    const { user } = await register("  Kevin.CC ", "secreto123");
    expect(user.username).toBe("kevin.cc");
  });

  it("no deja repetir usuario, aunque cambien las mayúsculas", async () => {
    await register("kevin");
    const res = await api("/auth/register", { body: { username: "KEVIN", password: "otra-clave", displayName: "Otro" } });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe("username_taken");
  });

  it.each([
    ["ab", "muy corto"],
    ["a".repeat(21), "muy largo"],
    ["kevín", "con tilde"],
    ["kevin carrera", "con espacio"],
  ])("rechaza el usuario %s (%s) con detalle por campo", async (username) => {
    const res = await api("/auth/register", { body: { username, password: "secreto123", displayName: "K" } });
    expect(res.status).toBe(400);
    expect(res.body.error.details.username).toBeDefined();
  });

  it("exige contraseña de al menos 8 caracteres y un nombre", async () => {
    const res = await api("/auth/register", { body: { username: "kevin", password: "corta", displayName: "  " } });
    expect(res.status).toBe(400);
    expect(res.body.error.details.password).toEqual(["Mínimo 8 caracteres"]);
    expect(res.body.error.details.displayName).toEqual(["Escribe tu nombre"]);
  });

  it("como mucho 30 registros por hora desde la misma IP", async () => {
    for (let i = 0; i < 30; i++) {
      const res = await api("/auth/register", {
        body: { username: `jugador${i}`, password: "secreto123", displayName: "J" },
        ip: "152.206.0.1",
      });
      expect(res.status).toBe(201);
    }
    const res = await api("/auth/register", {
      body: { username: "jugador30", password: "secreto123", displayName: "J" },
      ip: "152.206.0.1",
    });
    expect(res.status).toBe(429);
    expect(Number(res.headers.get("retry-after"))).toBeGreaterThan(0);
    const otherIp = await api("/auth/register", {
      body: { username: "jugador30", password: "secreto123", displayName: "J" },
      ip: "152.206.0.2",
    });
    expect(otherIp.status).toBe(201);
  });
});
