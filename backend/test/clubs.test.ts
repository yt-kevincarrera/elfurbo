import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, auditActions, requestClub } from "./fixtures";
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

  it("reintentar la misma solicitud (respuesta perdida) no crea duplicados", async () => {
    const { token } = await register("kevin");
    const first = await api("/clubs", { token, body: { name: "Pachanga" } });
    const again = await api("/clubs", { token, body: { name: "  pachanga " } });
    expect(again.status).toBe(200);
    expect(again.body.club.id).toBe(first.body.club.id);
    const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM clubs").first<{ n: number }>();
    expect(row!.n).toBe(1);
    for (let i = 0; i < 3; i++) await api("/clubs", { token, body: { name: "Pachanga" } });
    expect((await api("/clubs", { token, body: { name: "Otra pachanga" } })).status).toBe(201);
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

describe("GET /me con servidores", () => {
  it("al aprobarse, el servidor sale en clubs con el rol owner y desaparece de las solicitudes", async () => {
    const { clubId, owner } = await activeClub("kevin");
    const me = await api("/me", { token: owner.token });
    expect(me.body.clubs).toMatchObject([{ id: clubId, name: "Pachanga del sábado", status: "active", role: "owner" }]);
    expect(me.body.clubs[0].memberId).toEqual(expect.any(String));
    expect(me.body.clubRequests).toEqual([]);
  });

  it("no lista servidores de los que se fue ni de los que lo expulsaron", async () => {
    const { clubId, owner } = await activeClub("kevin");
    await env.DB.prepare("UPDATE members SET status = 'left' WHERE club_id = ?").bind(clubId).run();
    expect((await api("/me", { token: owner.token })).body.clubs).toEqual([]);
  });
});
