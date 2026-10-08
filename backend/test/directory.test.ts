import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { recomputeClub } from "../src/stats/job";
import { activeClub, addMember, auditActions, ownerMemberId } from "./fixtures";
import { api, register } from "./helpers";
import { seedMembers, seedWeekly } from "./stats-helpers";
import { apply, cmd } from "./sync-helpers";

const post = (path: string, token: string, body: unknown = {}) => api(path, { method: "POST", token, body });

async function publicClub(owner = "dueno", name = "Los Pinos", joinPolicy: "request" | "open" = "request") {
  const club = await activeClub(owner, name);
  await apply(club.owner.token, cmd(club.clubId, "club.setVisibility", { visibility: "public", joinPolicy }));
  return club;
}

describe("directorio", () => {
  it("solo salen los públicos y activos, con quien mira: miembro, pendiente o nada", async () => {
    const pub = await publicClub();
    await activeClub("otro", "Privado");
    const kevin = await register("kevin");
    const res = await api("/directory", { token: kevin.token });
    expect(res.status).toBe(200);
    expect(res.body.clubs).toMatchObject([
      { id: pub.clubId, name: "Los Pinos", kind: "group", tier: "new", members: 1, joinPolicy: "request", myStatus: "none" },
    ]);
    expect(res.body.next).toBeNull();
    expect((await api("/directory", { token: pub.owner.token })).body.clubs[0].myStatus).toBe("member");
    await post(`/clubs/${pub.clubId}/join`, kevin.token);
    expect((await api("/directory", { token: kevin.token })).body.clubs[0].myStatus).toBe("pending");
    expect((await api("/directory")).status).toBe(401);
  });

  it("busca por nombre o ciudad, filtra por provincia y tipo; ordena oficiales primero", async () => {
    const a = await publicClub("dueno.a", "Los Pinos");
    const b = await publicClub("dueno.b", "El Pre");
    await apply(b.owner.token, cmd(b.clubId, "club.updateProfile", { province: "vcl", city: "Santa Clara" }));
    await post(`/admin/clubs/${a.clubId}/official`, a.admin.token, { official: true });
    const kevin = await register("kevin");
    const names = async (qs: string) =>
      (await api(`/directory${qs}`, { token: kevin.token })).body.clubs.map((c: { name: string }) => c.name);
    expect(await names("")).toEqual(["Los Pinos", "El Pre"]);
    expect(await names("?q=santa")).toEqual(["El Pre"]);
    expect(await names("?q=pin")).toEqual(["Los Pinos"]);
    expect(await names("?province=vcl")).toEqual(["El Pre"]);
    expect(await names("?kind=tournament")).toEqual([]);
    expect((await api("/directory?province=marte", { token: kevin.token })).status).toBe(400);
  });

  it("pagina de 20 en 20", async () => {
    for (let i = 0; i < 21; i++) await publicClub(`dueno${i}`, `Club ${String(i).padStart(2, "0")}`);
    const kevin = await register("kevin");
    const first = await api("/directory", { token: kevin.token });
    expect(first.body.clubs).toHaveLength(20);
    expect(first.body.next).toBe(20);
    const second = await api(`/directory?cursor=20`, { token: kevin.token });
    expect(second.body.clubs).toHaveLength(1);
    expect(second.body.next).toBeNull();
  });

  it("el detalle: descripción, goleadores de la temporada y próximas jornadas; uno privado da 404", async () => {
    const pub = await publicClub();
    const staff = await ownerMemberId(pub.clubId);
    await seedWeekly(pub.clubId, await seedMembers(pub.clubId, 3), 3, staff, 2);
    await recomputeClub(env.DB, pub.clubId, new Date());
    await apply(
      pub.owner.token,
      cmd(pub.clubId, "matchday.create", { id: crypto.randomUUID(), startsAt: new Date(Date.now() + 86_400_000).toISOString(), place: "El Pre" }),
    );
    const kevin = await register("kevin");
    const res = await api(`/directory/${pub.clubId}`, { token: kevin.token });
    expect(res.status).toBe(200);
    expect(res.body.club).toMatchObject({ name: "Los Pinos", description: "", upcoming: [{ place: "El Pre" }] });
    expect(res.body.club.topScorers).toHaveLength(3);
    expect(res.body.club.topScorers[0]).toMatchObject({ goals: 6, played: 3 });
    const priv = await activeClub("otro", "Privado");
    expect((await api(`/directory/${priv.clubId}`, { token: kevin.token })).status).toBe(404);
  });
});

describe("pedir entrar", () => {
  it("con solicitud: queda pendiente (pedirlo otra vez da la misma), sale en /me y el admin la acepta", async () => {
    const pub = await publicClub();
    const kevin = await register("kevin");
    const first = await post(`/clubs/${pub.clubId}/join`, kevin.token, { message: "Juego de lateral" });
    expect(first.status).toBe(201);
    expect(first.body.status).toBe("pending");
    const again = await post(`/clubs/${pub.clubId}/join`, kevin.token);
    expect(again.body.request.id).toBe(first.body.request.id);

    expect((await api("/me", { token: kevin.token })).body.joinRequests).toMatchObject([
      { clubId: pub.clubId, clubName: "Los Pinos", status: "pending" },
    ]);
    expect((await api("/me", { token: pub.owner.token })).body.pendingJoinRequests).toMatchObject([
      { id: first.body.request.id, clubId: pub.clubId, clubName: "Los Pinos", displayName: "Kevin" },
    ]);

    const list = await api(`/clubs/${pub.clubId}/join-requests`, { token: pub.owner.token });
    expect(list.body.requests).toMatchObject([
      { id: first.body.request.id, username: "kevin", displayName: "Kevin", message: "Juego de lateral", played: 0 },
    ]);
    const accepted = await post(`/clubs/${pub.clubId}/join-requests/${first.body.request.id}/accept`, pub.owner.token);
    expect(accepted.status).toBe(200);
    const me = (await api("/me", { token: kevin.token })).body;
    expect(me.clubs).toMatchObject([{ id: pub.clubId, role: "player" }]);
    expect(me.joinRequests).toEqual([]);
    expect(await auditActions(pub.clubId)).toContain("join.accept");
    expect((await post(`/clubs/${pub.clubId}/join`, kevin.token)).body.error.code).toBe("already_member");
  });

  it("abierto: se entra al momento", async () => {
    const pub = await publicClub("dueno", "Los Pinos", "open");
    const kevin = await register("kevin");
    const res = await post(`/clubs/${pub.clubId}/join`, kevin.token);
    expect(res.status).toBe(201);
    expect(res.body.status).toBe("member");
    expect((await api("/me", { token: kevin.token })).body.clubs[0]).toMatchObject({ id: pub.clubId, role: "player" });
    expect(await auditActions(pub.clubId)).toContain("join.open");
  });

  it("rechazar: con la nota en /me; y quien se fue vuelve con su mismo perfil", async () => {
    const pub = await publicClub();
    const kevin = await register("kevin");
    const req = (await post(`/clubs/${pub.clubId}/join`, kevin.token)).body.request.id;
    await post(`/clubs/${pub.clubId}/join-requests/${req}/reject`, pub.owner.token, { note: "Estamos llenos" });
    expect((await api("/me", { token: kevin.token })).body.joinRequests).toMatchObject([
      { status: "rejected", note: "Estamos llenos" },
    ]);
    // Lo vuelve a pedir, entra, se va y vuelve: el mismo miembro.
    const again = (await post(`/clubs/${pub.clubId}/join`, kevin.token)).body.request.id;
    const first = (await post(`/clubs/${pub.clubId}/join-requests/${again}/accept`, pub.owner.token)).body.member.id;
    await apply(kevin.token, cmd(pub.clubId, "member.leave"));
    const third = (await post(`/clubs/${pub.clubId}/join`, kevin.token)).body.request.id;
    const back = (await post(`/clubs/${pub.clubId}/join-requests/${third}/accept`, pub.owner.token)).body.member.id;
    expect(back).toBe(first);
  });

  it("expulsado no puede; privado o inexistente da 404; retirar la solicitud", async () => {
    const pub = await publicClub();
    const yoan = await addMember(pub.clubId, "yoan", "player");
    await apply(pub.owner.token, cmd(pub.clubId, "member.ban", { memberId: yoan.memberId }));
    expect((await post(`/clubs/${pub.clubId}/join`, yoan.token)).body.error.code).toBe("banned_from_club");
    const priv = await activeClub("otro", "Privado");
    const kevin = await register("kevin");
    expect((await post(`/clubs/${priv.clubId}/join`, kevin.token)).status).toBe(404);
    expect((await post(`/clubs/nada/join`, kevin.token)).status).toBe(404);

    await post(`/clubs/${pub.clubId}/join`, kevin.token);
    expect((await api(`/clubs/${pub.clubId}/join`, { method: "DELETE", token: kevin.token })).status).toBe(204);
    expect((await api("/me", { token: kevin.token })).body.joinRequests).toEqual([]);
  });

  it("como mucho 5 pendientes a la vez", async () => {
    const kevin = await register("kevin");
    for (let i = 0; i < 5; i++) {
      const pub = await publicClub(`dueno${i}`, `Club ${i}`);
      expect((await post(`/clubs/${pub.clubId}/join`, kevin.token)).status).toBe(201);
    }
    const sixth = await publicClub("dueno6", "Club 6");
    expect((await post(`/clubs/${sixth.clubId}/join`, kevin.token)).body.error.code).toBe("too_many_join_requests");
  });

  it("solo owner y admin ven y contestan solicitudes", async () => {
    const pub = await publicClub();
    const player = await addMember(pub.clubId, "jugador", "player");
    const kevin = await register("kevin");
    const req = (await post(`/clubs/${pub.clubId}/join`, kevin.token)).body.request.id;
    expect((await api(`/clubs/${pub.clubId}/join-requests`, { token: player.token })).status).toBe(403);
    expect((await post(`/clubs/${pub.clubId}/join-requests/${req}/accept`, player.token)).status).toBe(403);
    expect((await post(`/clubs/${pub.clubId}/join-requests/nada/accept`, pub.owner.token)).status).toBe(404);
    const admin = await addMember(pub.clubId, "jefe", "admin");
    expect((await post(`/clubs/${pub.clubId}/join-requests/${req}/accept`, admin.token)).status).toBe(200);
  });
});

describe("página pública /s/:id", () => {
  const page = async (id: string) => {
    const res = await exports.default.fetch(`https://api.test/s/${id}`);
    return { status: res.status, html: await res.text() };
  };

  it("enseña el servidor público, escapado, con el enlace para pedir entrar", async () => {
    const pub = await publicClub("dueno", "Los <b>Pinos</b>");
    await apply(pub.owner.token, cmd(pub.clubId, "club.updateProfile", { description: "<script>alert(1)</script>", province: "hab" }));
    const { status, html } = await page(pub.clubId);
    expect(status).toBe(200);
    expect(html).toContain("Los &lt;b&gt;Pinos&lt;/b&gt;");
    expect(html).not.toContain("<script>alert");
    expect(html).toContain("La Habana");
    expect(html).toContain(`elfurbo://club/${pub.clubId}`);
  });

  it("uno privado o que no existe: la misma página de que no está", async () => {
    const priv = await activeClub("otro", "Privado");
    const a = await page(priv.clubId);
    const b = await page("nada");
    expect(a.status).toBe(404);
    expect(a.html).not.toContain("Privado");
    expect(a.html).toBe(b.html);
  });
});
