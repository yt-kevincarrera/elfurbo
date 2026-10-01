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
});
