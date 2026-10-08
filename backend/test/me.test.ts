import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addMember, requestClub } from "./fixtures";
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
    expect(res.body).toEqual({ user, settings: { showPrivateStats: true }, clubs: [], clubRequests: [] });
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

  it("DELETE: el dueño de un servidor activo tiene que transferirlo antes", async () => {
    const { owner } = await activeClub("kevin");
    const res = await api("/me", { method: "DELETE", token: owner.token, body: { password: "secreto123" } });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe("owner_must_transfer");
    expect((await api("/me", { token: owner.token })).status).toBe(200);
  });

  it("DELETE: sus perfiles quedan como 'Jugador eliminado' sin cuenta, y sus solicitudes pendientes se borran", async () => {
    const { clubId } = await activeClub("kevin");
    const raul = await addMember(clubId, "raul", "admin");
    await requestClub(raul.token, "Solicitud de Raúl");

    const res = await api("/me", { method: "DELETE", token: raul.token, body: { password: "secreto123" } });
    expect(res.status).toBe(204);
    const member = await env.DB.prepare("SELECT user_id, role, display_name FROM members WHERE id = ?")
      .bind(raul.memberId)
      .first();
    expect(member).toEqual({ user_id: null, role: "guest", display_name: "Jugador eliminado" });
    const pending = await env.DB.prepare("SELECT COUNT(*) AS n FROM clubs WHERE name = 'Solicitud de Raúl'").first<{ n: number }>();
    expect(pending!.n).toBe(0);
  });
});
