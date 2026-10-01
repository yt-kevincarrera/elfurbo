import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { api, login, register } from "./helpers";

describe("POST /auth/login", () => {
  it("entra con usuario y contraseña, sin importar mayúsculas ni espacios en el usuario", async () => {
    const { user } = await register("kevin", "secreto123");
    const res = await login(" KEVIN ", "secreto123");
    expect(res.status).toBe(200);
    expect(res.body.user).toEqual(user);
    expect((await api("/me", { token: res.body.token })).status).toBe(200);
  });

  it("contraseña mala y usuario inexistente dan el mismo error", async () => {
    await register("kevin", "secreto123");
    const wrong = await login("kevin", "otra-cosa");
    const unknown = await login("nadie", "otra-cosa");
    expect(wrong.status).toBe(401);
    expect(unknown.status).toBe(401);
    expect(wrong.body).toEqual(unknown.body);
    expect(wrong.body.error.code).toBe("invalid_credentials");
  });

  it("tras 10 fallos bloquea ese usuario 15 minutos, aunque luego acierte", async () => {
    await register("kevin", "secreto123");
    for (let i = 0; i < 10; i++) expect((await login("kevin", "mala")).status).toBe(401);
    const res = await login("kevin", "secreto123");
    expect(res.status).toBe(429);
    expect(res.body.error.code).toBe("too_many_attempts");
    const retryAfter = Number(res.headers.get("retry-after"));
    expect(retryAfter).toBeGreaterThan(14 * 60);
    expect(retryAfter).toBeLessThanOrEqual(15 * 60);
  });

  it("pasada la ventana de 15 minutos vuelve a dejar entrar", async () => {
    await register("kevin", "secreto123");
    for (let i = 0; i < 10; i++) await login("kevin", "mala");
    const old = new Date(Date.now() - 16 * 60 * 1000).toISOString();
    await env.DB.prepare("UPDATE login_attempts SET window_start = ?").bind(old).run();
    expect((await login("kevin", "secreto123")).status).toBe(200);
  });

  it("un acierto pone a cero el contador del usuario", async () => {
    await register("kevin", "secreto123");
    for (let i = 0; i < 9; i++) await login("kevin", "mala");
    expect((await login("kevin", "secreto123")).status).toBe(200);
    for (let i = 0; i < 9; i++) await login("kevin", "mala");
    expect((await login("kevin", "secreto123")).status).toBe(200);
  });

  it("CGNAT: 15 personas en la misma IP, cada una con un fallo, entran todas", async () => {
    for (let i = 0; i < 15; i++) await register(`jugador${i}`, "secreto123");
    for (let i = 0; i < 15; i++) {
      expect((await login(`jugador${i}`, "mala", "152.206.0.1")).status).toBe(401);
      expect((await login(`jugador${i}`, "secreto123", "152.206.0.1")).status).toBe(200);
    }
  });

  it("una cuenta suspendida no puede entrar", async () => {
    await register("kevin", "secreto123");
    await env.DB.prepare("UPDATE users SET status = 'suspended'").run();
    const res = await login("kevin", "secreto123");
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("account_suspended");
  });
});
