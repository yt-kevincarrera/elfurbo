import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions } from "./fixtures";
import { api } from "./helpers";

async function invite(clubId: string, token: string, body: Record<string, unknown> = {}) {
  return api(`/clubs/${clubId}/invites`, { token, body });
}


describe("crear invitaciones", () => {
  it("el owner crea una con código XXXX-XXXX, 1 uso y 7 días por defecto", async () => {
    const { clubId, owner } = await activeClub();
    const res = await invite(clubId, owner.token);
    expect(res.status).toBe(201);
    expect(res.body.invite).toMatchObject({ role: "player", maxUses: 1, uses: 0, targetMemberId: null });
    expect(res.body.invite.code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    const days = (Date.parse(res.body.invite.expiresAt) - Date.now()) / 86_400_000;
    expect(days).toBeGreaterThan(6.9);
    expect(days).toBeLessThanOrEqual(7);
    expect(await auditActions(clubId)).toContain("invite.create");
  });

  it("un admin invita como player o scorer, pero no como admin", async () => {
    const { clubId } = await activeClub();
    const admin = await addMember(clubId, "raul", "admin");
    expect((await invite(clubId, admin.token, { role: "scorer", maxUses: 20 })).status).toBe(201);
    const res = await invite(clubId, admin.token, { role: "admin" });
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("forbidden");
  });

  it("un player o un scorer no puede invitar", async () => {
    const { clubId } = await activeClub();
    for (const role of ["player", "scorer"] as const) {
      const m = await addMember(clubId, `m.${role}`, role);
      expect((await invite(clubId, m.token)).status, role).toBe(403);
    }
  });

  it("quien no es miembro recibe 404, aunque sea admin de otro servidor", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const res = await invite(a.clubId, b.owner.token);
    expect(res.status).toBe(404);
  });

  it("un admin que se fue o al que expulsaron ya no actúa en el servidor: 404", async () => {
    const { clubId } = await activeClub();
    const gone = await addMember(clubId, "seFue", "admin");
    const banned = await addMember(clubId, "baneado", "admin");
    await env.DB.prepare("UPDATE members SET status = 'left' WHERE id = ?").bind(gone.memberId).run();
    await env.DB.prepare("UPDATE members SET status = 'banned' WHERE id = ?").bind(banned.memberId).run();
    expect((await invite(clubId, gone.token)).status).toBe(404);
    expect((await invite(clubId, banned.token)).status).toBe(404);
  });

  it("valida usos (1–100) y días (1–30)", async () => {
    const { clubId, owner } = await activeClub();
    expect((await invite(clubId, owner.token, { maxUses: 0 })).status).toBe(400);
    expect((await invite(clubId, owner.token, { maxUses: 101 })).status).toBe(400);
    expect((await invite(clubId, owner.token, { expiresInDays: 31 })).status).toBe(400);
  });

  it("para reclamar un perfil sin cuenta: fuerza player y 1 uso; el perfil tiene que ser de este servidor", async () => {
    const { clubId, owner } = await activeClub();
    const guest = await addGuest(clubId);
    const res = await invite(clubId, owner.token, { targetMemberId: guest, role: "admin", maxUses: 50 });
    expect(res.body.invite).toMatchObject({ role: "player", maxUses: 1, targetMemberId: guest });

    const other = await activeClub("raul", "Otro");
    const foreignGuest = await addGuest(other.clubId);
    expect((await invite(clubId, owner.token, { targetMemberId: foreignGuest })).status).toBe(400);
  });

  it("en un servidor suspendido no se crean invitaciones", async () => {
    const { clubId, owner } = await activeClub();
    await env.DB.prepare("UPDATE clubs SET status = 'suspended' WHERE id = ?").bind(clubId).run();
    const res = await invite(clubId, owner.token);
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("club_suspended");
  });
});

describe("listar y revocar", () => {
  it("lista solo las que aún sirven; revocar la saca de la lista", async () => {
    const { clubId, owner } = await activeClub();
    const a = (await invite(clubId, owner.token)).body.invite.code;
    const b = (await invite(clubId, owner.token)).body.invite.code;
    expect((await api(`/clubs/${clubId}/invites/${a}/revoke`, { method: "POST", token: owner.token })).status).toBe(204);
    const list = await api(`/clubs/${clubId}/invites`, { token: owner.token });
    expect(list.body.invites.map((i: { code: string }) => i.code)).toEqual([b]);
    expect(await auditActions(clubId)).toContain("invite.revoke");
  });

  it("un player no ve ni revoca invitaciones", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token)).body.invite.code;
    const raul = await addMember(clubId, "raul", "player");
    expect((await api(`/clubs/${clubId}/invites`, { token: raul.token })).status).toBe(403);
    expect((await api(`/clubs/${clubId}/invites/${code}/revoke`, { method: "POST", token: raul.token })).status).toBe(403);
  });

  it("no se puede revocar una invitación de otro servidor", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const code = (await invite(b.clubId, b.owner.token)).body.invite.code;
    expect((await api(`/clubs/${a.clubId}/invites/${code}/revoke`, { method: "POST", token: a.owner.token })).status).toBe(404);
    const list = await api(`/clubs/${b.clubId}/invites`, { token: b.owner.token });
    expect(list.body.invites.map((i: { code: string }) => i.code)).toEqual([code]);
  });
});
