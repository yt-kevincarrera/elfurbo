import { describe, expect, it } from "vitest";
import { api, login, register } from "./helpers";

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
  it("GET devuelve el usuario y, por ahora, ningún servidor", async () => {
    const { token, user } = await register();
    const res = await api("/me", { token });
    expect(res.body).toEqual({ user, clubs: [] });
  });
});
