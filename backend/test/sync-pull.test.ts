import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addMember, superadmin } from "./fixtures";
import { api, register } from "./helpers";
import { apply, cmd, pullAll } from "./sync-helpers";

describe("POST /sync/pull", () => {
  it("sin cursor: foto completa del servidor (club, miembros, temporada inicial)", async () => {
    const { clubId, owner } = await activeClub();
    const { clubs, removed } = await pullAll(owner.token);
    expect(removed).toEqual([]);
    const c = clubs[clubId]!;
    expect(c.snapshot).toBe(true);
    expect(c.hasMore).toBe(false);
    expect(c.cursor).toBeGreaterThan(0);
    expect(c.upserts.club).toMatchObject([{ id: clubId, name: "Pachanga del sábado", status: "active", settings: { timezone: "America/Havana" } }]);
    expect(c.upserts.member).toMatchObject([{ role: "owner", userId: owner.user.id, displayName: "Dueño", status: "active" }]);
    expect(c.upserts.season).toEqual([
      { id: expect.any(String), name: String(new Date().getFullYear()), startDate: `${new Date().getFullYear()}-01-01`, isActive: true, isClosed: false },
    ]);
  });

  it("con cursor: solo lo que cambió después", async () => {
    const { clubId, owner } = await activeClub();
    const first = await pullAll(owner.token);
    const cursor = first.clubs[clubId]!.cursor;
    expect((await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]).toEqual({
      cursor,
      hasMore: false,
      snapshot: false,
      upserts: {},
      deletes: {},
    });

    const id = crypto.randomUUID();
    await apply(owner.token, cmd(clubId, "member.createGuest", { id, displayName: "Yoandry" }));
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.snapshot).toBe(false);
    expect(next.cursor).toBeGreaterThan(cursor);
    expect(next.upserts).toEqual({
      member: [{ id, userId: null, role: "guest", status: "active", displayName: "Yoandry", nickname: null, claimedAt: null }],
    });
  });

  it("una entidad que cambia varias veces llega una sola vez, con su estado actual", async () => {
    const { clubId, owner } = await activeClub();
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    const id = crypto.randomUUID();
    await apply(owner.token, cmd(clubId, "member.createGuest", { id, displayName: "Uno" }));
    await apply(owner.token, cmd(clubId, "member.update", { memberId: id, displayName: "Dos" }));
    await apply(owner.token, cmd(clubId, "member.update", { memberId: id, nickname: "El Tres" }));
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.upserts.member).toMatchObject([{ id, displayName: "Dos", nickname: "El Tres" }]);
  });

  it("lo borrado llega en deletes", async () => {
    const { clubId, owner } = await activeClub();
    const seasonId = crypto.randomUUID();
    await apply(owner.token, cmd(clubId, "season.create", { id: seasonId, name: "Verano", startDate: "2026-07-01" }));
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    await apply(owner.token, cmd(clubId, "season.delete", { seasonId }));
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.deletes).toEqual({ season: [seasonId] });
    expect(next.upserts).toEqual({});
  });

  it("pagina de 500 en 500 con hasMore", async () => {
    const { clubId, owner } = await activeClub();
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    const at = new Date().toISOString();
    const inserts = Array.from({ length: 520 }, (_, i) =>
      env.DB.prepare("INSERT INTO changes (club_id, entity, entity_key, op, at) VALUES (?, 'member', ?, 'upsert', ?)").bind(clubId, `fantasma-${i}`, at),
    );
    await env.DB.batch(inserts);
    const page1 = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(page1.hasMore).toBe(true);
    expect(page1.deletes.member).toHaveLength(500);
    const page2 = (await pullAll(owner.token, { [clubId]: page1.cursor })).clubs[clubId]!;
    expect(page2.hasMore).toBe(false);
    expect(page2.deletes.member).toHaveLength(20);
  });

  it("un servidor nuevo para la app (aunque no lo pida) llega como foto completa", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const pepe = await addMember(a.clubId, "pepe", "player");
    const cursorA = (await pullAll(pepe.token)).clubs[a.clubId]!.cursor;
    await env.DB.prepare(
      "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, ?, 'player', 'Pepe', ?, ?)",
    )
      .bind(crypto.randomUUID(), b.clubId, pepe.user.id, new Date().toISOString(), new Date().toISOString())
      .run();
    const res = await pullAll(pepe.token, { [a.clubId]: cursorA });
    expect(res.clubs[b.clubId]!.snapshot).toBe(true);
    expect(res.clubs[a.clubId]!.snapshot).toBe(false);
  });

  it("si lo expulsan o se va, el servidor aparece en removed y no se le mandan sus datos", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const cursor = (await pullAll(raul.token)).clubs[clubId]!.cursor;
    await apply(owner.token, cmd(clubId, "member.ban", { memberId: raul.memberId }));
    const res = await pullAll(raul.token, { [clubId]: cursor });
    expect(res.removed).toEqual([clubId]);
    expect(res.clubs).toEqual({});
  });

  it("pedir un servidor ajeno no da datos: va a removed", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const res = await pullAll(a.owner.token, { [b.clubId]: 0 });
    expect(Object.keys(res.clubs)).toEqual([a.clubId]);
    expect(res.removed).toEqual([b.clubId]);
  });

  it("el superadmin puede leer cualquier servidor pidiéndolo", async () => {
    const { clubId } = await activeClub();
    const boss = await superadmin("el.jefe");
    const res = await pullAll(boss.token, { [clubId]: 0, "no-existe": 0 });
    expect(res.clubs[clubId]!.snapshot).toBe(true);
    expect(res.removed).toEqual(["no-existe"]);
  });

  it("lo que cambian los endpoints con conexión también llega: aceptar una invitación", async () => {
    const { clubId, owner } = await activeClub();
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    const code = (await api(`/clubs/${clubId}/invites`, { token: owner.token, body: {} })).body.invite.code;
    const raul = await register("raul", "secreto123", "Raúl");
    await api(`/invites/${code}/accept`, { method: "POST", token: raul.token });
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.upserts.member).toMatchObject([{ userId: raul.user.id, displayName: "Raúl", role: "player" }]);
  });

  it("y borrar una cuenta: su perfil llega como Jugador eliminado", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    await api("/me", { method: "DELETE", token: raul.token, body: { password: "secreto123" } });
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.upserts.member).toMatchObject([{ id: raul.memberId, userId: null, role: "guest", displayName: "Jugador eliminado" }]);
  });

  it("valida los cursores", async () => {
    const { token } = await register("kevin");
    expect((await api("/sync/pull", { token, body: { cursors: { x: -1 } } })).status).toBe(400);
    expect((await api("/sync/pull", { token, body: {} })).status).toBe(400);
  });
});
