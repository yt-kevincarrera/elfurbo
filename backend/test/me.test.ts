import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { api, insertRecoveryCode, login, register } from "./helpers";

describe("POST /auth/password", () => {
  it("cambia la contraseña y cierra las demás sesiones, no la actual", async () => {
    const { token } = await register("kevin", "secreto123");
    const other = (await login("kevin", "secreto123")).body.token;

    const res = await api("/auth/password", {
      token,
      body: { currentPassword: "secreto123", newPassword: "nueva-clave" },
    });
    expect(res.status).toBe(204);
    expect((await api("/me", { token })).status).toBe(200);
    expect((await api("/me", { token: other })).status).toBe(401);
    expect((await login("kevin", "nueva-clave")).status).toBe(200);
  });

  it("con la contraseña actual mal: 401 y no cambia nada", async () => {
    const { token } = await register("kevin", "secreto123");
    const res = await api("/auth/password", { token, body: { currentPassword: "mala", newPassword: "nueva-clave" } });
    expect(res.status).toBe(401);
    expect((await login("kevin", "secreto123")).status).toBe(200);
  });

  it("sin sesión: 401", async () => {
    const res = await api("/auth/password", { body: { currentPassword: "a", newPassword: "nueva-clave" } });
    expect(res.status).toBe(401);
  });
});

describe("/me", () => {
  it("GET devuelve el usuario, sin servidores ni solicitudes al principio", async () => {
    const { token, user } = await register();
    const res = await api("/me", { token });
    expect(res.body).toEqual({ user, clubs: [], clubRequests: [] });
  });

  it("DELETE con la contraseña mal: 401 y la cuenta sigue", async () => {
    const { token } = await register("kevin", "secreto123");
    const res = await api("/me", { method: "DELETE", token, body: { password: "mala" } });
    expect(res.status).toBe(401);
    expect((await api("/me", { token })).status).toBe(200);
  });

  it("DELETE borra la cuenta, sus sesiones y sus códigos, y libera el nombre", async () => {
    const { token, user } = await register("kevin", "secreto123");
    await login("kevin", "secreto123");
    await insertRecoveryCode(user.id, "ABCDEFGH");

    const res = await api("/me", { method: "DELETE", token, body: { password: "secreto123" } });
    expect(res.status).toBe(204);
    expect((await api("/me", { token })).status).toBe(401);
    for (const table of ["users", "sessions", "recovery_codes"]) {
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
      expect(row!.n, table).toBe(0);
    }
    await register("kevin", "otra-clave-1");
  });

});
