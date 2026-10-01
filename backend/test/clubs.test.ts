import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { auditActions, requestClub } from "./fixtures";
import { api, register } from "./helpers";

describe("POST /clubs (solicitar servidor)", () => {
  it("queda pendiente, con los ajustes por defecto, y aparece en /me como solicitud", async () => {
    const { token } = await register("kevin");
    const res = await api("/clubs", {
      token,
      body: { name: "  Pachanga del sábado ", description: "Cancha de 23", requestNote: "Somos 20" },
    });
    expect(res.status).toBe(201);
    expect(res.body.club).toMatchObject({ name: "Pachanga del sábado", status: "pending" });

    const row = await env.DB.prepare("SELECT settings FROM clubs WHERE id = ?").bind(res.body.club.id).first<{ settings: string }>();
    expect(JSON.parse(row!.settings)).toEqual({
      matchdayCreators: "members",
      reportValidation: "confirm",
      confirmationsNeeded: 2,
      closeAfterHours: 72,
      timezone: "America/Havana",
    });

    const me = await api("/me", { token });
    expect(me.body.clubs).toEqual([]);
    expect(me.body.clubRequests).toMatchObject([{ id: res.body.club.id, name: "Pachanga del sábado", status: "pending", reviewNote: null }]);
    expect(await auditActions(res.body.club.id)).toEqual(["club.request"]);
  });

  it("exige sesión y un nombre de 3 a 40 caracteres", async () => {
    expect((await api("/clubs", { body: { name: "Pachanga" } })).status).toBe(401);
    const { token } = await register("kevin");
    const res = await api("/clubs", { token, body: { name: "ab" } });
    expect(res.status).toBe(400);
    expect(res.body.error.details.name).toEqual(["Mínimo 3 caracteres"]);
  });

  it("como mucho 3 servidores pendientes o activos por persona; los rechazados no cuentan", async () => {
    const { token, user } = await register("kevin");
    for (const n of ["Uno", "Dos", "Tres"]) await requestClub(token, `Servidor ${n}`);
    const fourth = await api("/clubs", { token, body: { name: "Servidor Cuatro" } });
    expect(fourth.status).toBe(409);
    expect(fourth.body.error.code).toBe("too_many_clubs");

    await env.DB.prepare("UPDATE clubs SET status = 'rejected' WHERE owner_user_id = ? AND name = 'Servidor Uno'").bind(user.id).run();
    expect((await api("/clubs", { token, body: { name: "Servidor Cuatro" } })).status).toBe(201);
  });
});
