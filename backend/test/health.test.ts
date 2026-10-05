import { describe, expect, it } from "vitest";
import { api, register } from "./helpers";

describe("infraestructura HTTP", () => {
  it("GET /health responde con el entorno", async () => {
    const res = await api("/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true, environment: "local" });
  });

  it("con MIN_SUPPORTED_BUILD, una app más vieja (o sin build) no sincroniza: 426", async () => {
    const { env } = await import("cloudflare:workers");
    const { exports } = await import("cloudflare:workers");
    const reg = await register();
    const old = env.MIN_SUPPORTED_BUILD;
    (env as { MIN_SUPPORTED_BUILD?: string }).MIN_SUPPORTED_BUILD = "9";
    try {
      const pull = (build?: string) =>
        exports.default.fetch("https://api.test/sync/pull", {
          method: "POST",
          headers: {
            authorization: `Bearer ${reg.token}`,
            "content-type": "application/json",
            ...(build ? { "x-app-build": build } : {}),
          },
          body: JSON.stringify({ cursors: {} }),
        });
      const none = await pull();
      expect(none.status).toBe(426);
      expect(((await none.json()) as { error: { code: string } }).error.code).toBe("app_outdated");
      expect((await pull("8")).status).toBe(426);
      expect((await pull("9")).status).toBe(200);
      // El resto de la API sigue: se puede entrar y ver la versión nueva.
      expect((await api("/me", { token: reg.token })).status).toBe(200);
    } finally {
      (env as { MIN_SUPPORTED_BUILD?: string }).MIN_SUPPORTED_BUILD = old;
    }
  });

  it("una ruta desconocida da 404 en JSON", async () => {
    const res = await api("/no-existe");
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe("not_found");
  });

  it("JSON roto da 400 invalid_input, no 500", async () => {
    const res = await api("/auth/register", { body: "{esto no es json" });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe("invalid_input");
  });

  it("un cuerpo que no es un objeto da 400", async () => {
    const res = await api("/auth/register", { body: [1, 2, 3] });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe("invalid_input");
  });

  it("un cuerpo de más de 64 KB da 413", async () => {
    const res = await api("/auth/register", { body: { username: "x".repeat(70 * 1024) } });
    expect(res.status).toBe(413);
    expect(res.body.error.code).toBe("payload_too_large");
  });
});
