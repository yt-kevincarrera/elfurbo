import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions, superadmin } from "./fixtures";
import { api, register } from "./helpers";

async function invite(clubId: string, token: string, body: Record<string, unknown> = {}) {
  return api(`/clubs/${clubId}/invites`, { token, body });
}

const accept = (code: string, token: string) => api(`/invites/${code}/accept`, { method: "POST", token });

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

  it("un admin no ve ni revoca las invitaciones de admin del dueño (no puede colar admins)", async () => {
    const { clubId, owner } = await activeClub();
    const adminCode = (await invite(clubId, owner.token, { role: "admin", maxUses: 50 })).body.invite.code;
    const playerCode = (await invite(clubId, owner.token)).body.invite.code;
    const raul = await addMember(clubId, "raul", "admin");
    const list = await api(`/clubs/${clubId}/invites`, { token: raul.token });
    expect(list.body.invites.map((i: { code: string }) => i.code)).toEqual([playerCode]);
    expect((await api(`/clubs/${clubId}/invites/${adminCode}/revoke`, { method: "POST", token: raul.token })).status).toBe(403);
    const mine = await api(`/clubs/${clubId}/invites`, { token: owner.token });
    expect(mine.body.invites).toHaveLength(2);
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

describe("ver y aceptar", () => {
  it("la vista previa no pide sesión y acepta el código en minúsculas y sin guion", async () => {
    const { clubId, owner } = await activeClub();
    const code: string = (await invite(clubId, owner.token)).body.invite.code;
    const res = await api(`/invites/${code.toLowerCase().replace("-", "")}`);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ club: { id: clubId, name: "Pachanga del sábado" }, role: "player", claim: null });
  });

  it("aceptar crea el miembro con el rol de la invitación y el servidor sale en /me", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token, { role: "scorer" })).body.invite.code;
    const raul = await register("raul", "secreto123", "Raúl");
    const res = await accept(code, raul.token);
    expect(res.status).toBe(201);
    expect(res.body.member).toMatchObject({ role: "scorer", displayName: "Raúl" });
    const me = await api("/me", { token: raul.token });
    expect(me.body.clubs).toMatchObject([{ id: clubId, role: "scorer" }]);
    expect(await auditActions(clubId)).toContain("invite.accept");
  });

  it("aceptar dos veces (reintento con mala conexión): 409 y el uso cuenta una sola vez", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token, { maxUses: 5 })).body.invite.code;
    const raul = await register("raul");
    expect((await accept(code, raul.token)).status).toBe(201);
    const again = await accept(code, raul.token);
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe("already_member");
    expect((await api(`/clubs/${clubId}/invites`, { token: owner.token })).body.invites[0].uses).toBe(1);
  });

  it("cuando se agotan los usos deja de valer", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token, { maxUses: 1 })).body.invite.code;
    expect((await accept(code, (await register("raul")).token)).status).toBe(201);
    const late = await accept(code, (await register("pepe")).token);
    expect(late.status).toBe(404);
    expect(late.body.error.code).toBe("invite_invalid");
  });

  it("revocada: ni se ve ni se acepta", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token)).body.invite.code;
    await api(`/clubs/${clubId}/invites/${code}/revoke`, { method: "POST", token: owner.token });
    expect((await api(`/invites/${code}`)).status).toBe(404);
    expect((await accept(code, (await register("raul")).token)).status).toBe(404);
  });

  it("caducada: no vale", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token)).body.invite.code;
    await env.DB.prepare("UPDATE invites SET expires_at = ?").bind(new Date(Date.now() - 1000).toISOString()).run();
    expect((await accept(code, (await register("raul")).token)).status).toBe(404);
  });

  it("un expulsado no vuelve a entrar; uno que se fue vuelve con su mismo perfil", async () => {
    const { clubId, owner } = await activeClub();
    const banned = await addMember(clubId, "baneado", "player");
    const gone = await addMember(clubId, "seFue", "player");
    await env.DB.prepare("UPDATE members SET status = 'banned' WHERE id = ?").bind(banned.memberId).run();
    await env.DB.prepare("UPDATE members SET status = 'left' WHERE id = ?").bind(gone.memberId).run();
    const code = (await invite(clubId, owner.token, { maxUses: 5 })).body.invite.code;

    const b = await accept(code, banned.token);
    expect(b.status).toBe(403);
    expect(b.body.error.code).toBe("banned_from_club");
    const g = await accept(code, gone.token);
    expect(g.status).toBe(201);
    expect(g.body.member.id).toBe(gone.memberId);
  });

  it("reclamar un perfil sin cuenta: se queda con ese perfil (y su historial)", async () => {
    const { clubId, owner } = await activeClub();
    const guest = await addGuest(clubId, "Yoandry, el primo de Raúl");
    const code = (await invite(clubId, owner.token, { targetMemberId: guest })).body.invite.code;
    expect((await api(`/invites/${code}`)).body.claim).toEqual({ displayName: "Yoandry, el primo de Raúl" });

    const yoandry = await register("yoandry");
    const res = await accept(code, yoandry.token);
    expect(res.status).toBe(201);
    expect(res.body.member).toEqual({ id: guest, role: "player", displayName: "Yoandry, el primo de Raúl" });
    const row = await env.DB.prepare("SELECT user_id, role, claimed_at FROM members WHERE id = ?").bind(guest).first<{
      user_id: string;
      role: string;
      claimed_at: string;
    }>();
    expect(row).toMatchObject({ user_id: yoandry.user.id, role: "player" });
    expect(row!.claimed_at).toEqual(expect.any(String));
  });

  it("quien ya es miembro no puede reclamar además un perfil sin cuenta", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const guest = await addGuest(clubId);
    const code = (await invite(clubId, owner.token, { targetMemberId: guest })).body.invite.code;
    expect((await accept(code, raul.token)).status).toBe(409);
    const row = await env.DB.prepare("SELECT user_id FROM members WHERE id = ?").bind(guest).first<{ user_id: string | null }>();
    expect(row!.user_id).toBeNull();
  });

  it("si el perfil sin cuenta ya no está disponible, falla sin gastar el uso", async () => {
    const { clubId, owner } = await activeClub();
    const guest = await addGuest(clubId);
    const code = (await invite(clubId, owner.token, { targetMemberId: guest })).body.invite.code;
    await env.DB.prepare("UPDATE members SET status = 'banned' WHERE id = ?").bind(guest).run();
    expect((await accept(code, (await register("raul")).token)).status).toBe(404);
    const row = await env.DB.prepare("SELECT uses FROM invites").first<{ uses: number }>();
    expect(row!.uses).toBe(0);
  });

  it("aceptar exige sesión; un servidor suspendido no admite gente nueva", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token)).body.invite.code;
    expect((await api(`/invites/${code}/accept`, { method: "POST" })).status).toBe(401);
    await env.DB.prepare("UPDATE clubs SET status = 'suspended' WHERE id = ?").bind(clubId).run();
    expect((await accept(code, (await register("raul")).token)).status).toBe(404);
  });
});

describe("página /i/<código>", () => {
  async function page(path: string) {
    const res = await exports.default.fetch(`https://api.test${path}`);
    return { status: res.status, headers: res.headers, html: await res.text() };
  }

  it("muestra el servidor, el código y el enlace a la app", async () => {
    const { clubId, owner } = await activeClub();
    const code: string = (await invite(clubId, owner.token)).body.invite.code;
    const res = await page(`/i/${code}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.html).toContain("Pachanga del sábado");
    expect(res.html).toContain(code);
    expect(res.html).toContain(`elfurbo://invite/${code.replace("-", "")}`);
    expect(res.html).toContain('href="/app/download"');
  });

  it("escapa el nombre y la descripción del servidor (los escribe cualquiera)", async () => {
    const owner = await register("kevin");
    const admin = await superadmin();
    const res = await api("/clubs", {
      token: owner.token,
      body: { name: `<script>alert(1)</script>`, description: `"><img src=x onerror=alert(2)>` },
    });
    await api(`/admin/clubs/${res.body.club.id}/approve`, { method: "POST", token: admin.token });
    const code = (await invite(res.body.club.id, owner.token)).body.invite.code;
    const html = (await page(`/i/${code}`)).html;
    expect(html).not.toContain("<script>alert");
    expect(html).not.toContain("<img");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
  });

  it("si no vale, da 404 con un mensaje claro", async () => {
    const res = await page("/i/NOEXISTE");
    expect(res.status).toBe(404);
    expect(res.html).toContain("Invitación no válida");
  });
});
