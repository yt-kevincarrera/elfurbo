import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions, ownerMemberId, requestClub, superadmin } from "./fixtures";
import { api, register } from "./helpers";

const post = (path: string, token: string, body?: unknown) => api(path, { method: "POST", token, body });

describe("panel del superadmin: acceso", () => {
  it("un usuario normal recibe 403 en todo /admin", async () => {
    const { token } = await register("kevin");
    for (const path of ["/admin/clubs", "/admin/users", "/admin/metrics"]) {
      const res = await api(path, { token });
      expect(res.status, path).toBe(403);
      expect(res.body.error.code).toBe("forbidden");
    }
  });
});

describe("panel del superadmin: servidores", () => {
  it("lista las solicitudes pendientes con el dueño y la nota", async () => {
    const owner = await register("kevin");
    const admin = await superadmin();
    const id = await requestClub(owner.token, "Pachanga", { requestNote: "Somos 20 en Centro Habana" });
    const res = await api("/admin/clubs?status=pending", { token: admin.token });
    expect(res.body.clubs).toMatchObject([
      { id, name: "Pachanga", status: "pending", ownerUsername: "kevin", requestNote: "Somos 20 en Centro Habana", members: 0 },
    ]);
    expect((await api("/admin/clubs?status=active", { token: admin.token })).body.clubs).toEqual([]);
    expect((await api("/admin/clubs?status=raro", { token: admin.token })).status).toBe(400);
  });

  it("busca por nombre o por usuario del dueño, sin que % o _ hagan de comodín", async () => {
    const admin = await superadmin();
    const a = await register("kevin");
    const b = await register("raul");
    await requestClub(a.token, "Fútbol 100%");
    await requestClub(b.token, "Los del barrio");
    const search = async (q: string) =>
      (await api(`/admin/clubs?q=${encodeURIComponent(q)}`, { token: admin.token })).body.clubs.map((c: { name: string }) => c.name);
    expect(await search("barrio")).toEqual(["Los del barrio"]);
    expect(await search("RAUL")).toEqual(["Los del barrio"]);
    expect(await search("100%")).toEqual(["Fútbol 100%"]);
    expect(await search("%")).toEqual(["Fútbol 100%"]);
  });

  it("aprobar: pasa a activo, el solicitante queda como owner y se audita", async () => {
    const { clubId, owner } = await activeClub("kevin");
    const member = await env.DB.prepare("SELECT user_id, role, display_name FROM members WHERE club_id = ?")
      .bind(clubId)
      .first<{ user_id: string; role: string; display_name: string }>();
    expect(member).toEqual({ user_id: owner.user.id, role: "owner", display_name: "Dueño" });
    expect(await auditActions(clubId)).toEqual(["club.request", "club.approve"]);
  });

  it("solo se aprueba o rechaza lo pendiente: 409 si ya está activo", async () => {
    const { clubId, admin } = await activeClub("kevin");
    const res = await post(`/admin/clubs/${clubId}/approve`, admin.token);
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe("invalid_state");
    expect((await post(`/admin/clubs/${clubId}/reject`, admin.token, {})).status).toBe(409);
    expect((await post("/admin/clubs/no-existe/approve", admin.token)).status).toBe(404);
  });

  it("rechazar con motivo: el solicitante lo ve en /me", async () => {
    const owner = await register("kevin");
    const admin = await superadmin();
    const id = await requestClub(owner.token);
    const res = await post(`/admin/clubs/${id}/reject`, admin.token, { note: "Nombre ofensivo" });
    expect(res.body.club.status).toBe("rejected");
    const me = await api("/me", { token: owner.token });
    expect(me.body.clubRequests).toMatchObject([{ id, status: "rejected", reviewNote: "Nombre ofensivo" }]);
  });

  it("suspender y reactivar; el detalle muestra dueño y miembros por rol", async () => {
    const { clubId, admin } = await activeClub("kevin");
    await addMember(clubId, "raul", "player");
    await addGuest(clubId);
    expect((await post(`/admin/clubs/${clubId}/suspend`, admin.token, { note: "Spam" })).body.club.status).toBe("suspended");
    const detail = await api(`/admin/clubs/${clubId}`, { token: admin.token });
    expect(detail.body).toMatchObject({
      club: { status: "suspended" },
      owner: { username: "kevin" },
      membersByRole: { owner: 1, player: 1, guest: 1 },
    });
    expect((await post(`/admin/clubs/${clubId}/reactivate`, admin.token)).body.club.status).toBe("active");
    expect(await auditActions(clubId)).toEqual(["club.request", "club.approve", "club.suspend", "club.reactivate"]);
  });

  it("transferir: el elegido pasa a owner y el anterior a admin", async () => {
    const { clubId, admin } = await activeClub("kevin");
    const oldOwnerMember = await ownerMemberId(clubId);
    const raul = await addMember(clubId, "raul", "player");
    const res = await post(`/admin/clubs/${clubId}/transfer`, admin.token, { memberId: raul.memberId });
    expect(res.status).toBe(200);
    const roles = await env.DB.prepare("SELECT id, role FROM members WHERE club_id = ? ORDER BY role").bind(clubId).all();
    expect(roles.results).toEqual(
      expect.arrayContaining([
        { id: oldOwnerMember, role: "admin" },
        { id: raul.memberId, role: "owner" },
      ]),
    );
    const club = await env.DB.prepare("SELECT owner_user_id FROM clubs WHERE id = ?").bind(clubId).first<{ owner_user_id: string }>();
    expect(club!.owner_user_id).toBe(raul.user.id);
  });

  it("no se transfiere a un jugador sin cuenta ni a alguien de otro servidor", async () => {
    const { clubId, admin } = await activeClub("kevin");
    const guest = await addGuest(clubId);
    const other = await activeClub("raul", "Otro servidor");
    const outsider = await addMember(other.clubId, "pepe", "player");
    expect((await post(`/admin/clubs/${clubId}/transfer`, admin.token, { memberId: guest })).status).toBe(400);
    expect((await post(`/admin/clubs/${clubId}/transfer`, admin.token, { memberId: outsider.memberId })).status).toBe(400);
  });
});
