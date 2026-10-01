import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions, ownerMemberId } from "./fixtures";
import { api, login } from "./helpers";

const issue = (clubId: string, memberId: string, token: string) =>
  api(`/clubs/${clubId}/members/${memberId}/recovery-code`, { method: "POST", token });

describe("códigos de recuperación desde el servidor", () => {
  it("el owner genera uno para un jugador; con él se cambia la contraseña", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const res = await issue(clubId, raul.memberId, owner.token);
    expect(res.status).toBe(201);
    expect(res.body.code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    const recover = await api("/auth/recover", { body: { username: "raul", code: res.body.code, newPassword: "nueva-clave" } });
    expect(recover.status).toBe(200);
    expect((await login("raul", "nueva-clave")).status).toBe(200);
    expect(await auditActions(clubId)).toContain("recovery.issue");
  });

  it("solo vale el último código generado", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const first = (await issue(clubId, raul.memberId, owner.token)).body.code;
    await issue(clubId, raul.memberId, owner.token);
    const res = await api("/auth/recover", { body: { username: "raul", code: first, newPassword: "nueva-clave" } });
    expect(res.status).toBe(400);
  });

  it("un admin puede para scorer y player, pero no para otro admin ni para el owner", async () => {
    const { clubId } = await activeClub();
    const admin = await addMember(clubId, "admin1", "admin");
    const otherAdmin = await addMember(clubId, "admin2", "admin");
    const scorer = await addMember(clubId, "anotador", "scorer");
    expect((await issue(clubId, scorer.memberId, admin.token)).status).toBe(201);
    expect((await issue(clubId, otherAdmin.memberId, admin.token)).status).toBe(403);
    expect((await issue(clubId, await ownerMemberId(clubId), admin.token)).status).toBe(403);
  });

  it("un player no puede; ni para sí mismo, ni para un sin cuenta", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const pepe = await addMember(clubId, "pepe", "player");
    const guest = await addGuest(clubId);
    expect((await issue(clubId, pepe.memberId, raul.token)).status).toBe(403);
    expect((await issue(clubId, await ownerMemberId(clubId), owner.token)).status).toBe(403);
    expect((await issue(clubId, guest, owner.token)).status).toBe(403);
  });

  it("no sirve para miembros de otro servidor", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const pepe = await addMember(b.clubId, "pepe", "player");
    expect((await issue(a.clubId, pepe.memberId, a.owner.token)).status).toBe(404);
    expect((await issue(b.clubId, pepe.memberId, a.owner.token)).status).toBe(404);
  });
});
