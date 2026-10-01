import { describe, expect, it } from "vitest";
import { api } from "./helpers";

describe("infraestructura HTTP", () => {
  it("GET /health responde con el entorno", async () => {
    const res = await api("/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true, environment: "local" });
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
