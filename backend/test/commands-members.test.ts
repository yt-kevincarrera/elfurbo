import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions, ownerMemberId } from "./fixtures";
import { api } from "./helpers";
import { apply, cmd, rejection } from "./sync-helpers";

async function member(id: string) {
  return env.DB.prepare("SELECT role, status, display_name, nickname, user_id FROM members WHERE id = ?").bind(id).first();
}

describe("member.createGuest", () => {
  it("el staff crea jugadores sin cuenta con el id que pone la app", async () => {
    const { clubId } = await activeClub();
    const scorer = await addMember(clubId, "anotador", "scorer");
    const id = crypto.randomUUID();
    await apply(scorer.token, cmd(clubId, "member.createGuest", { id, displayName: " Yoandry ", nickname: "El primo" }));
    expect(await member(id)).toEqual({ role: "guest", status: "active", display_name: "Yoandry", nickname: "El primo", user_id: null });
  });

  it("un player no puede (evita perfiles inventados)", async () => {
    const { clubId } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    expect(await rejection(raul.token, cmd(clubId, "member.createGuest", { id: crypto.randomUUID(), displayName: "Messi" }))).toBe("forbidden");
  });

  it("el perfil creado se puede reclamar con una invitación", async () => {
    const { clubId, owner } = await activeClub();
    const id = crypto.randomUUID();
    await apply(owner.token, cmd(clubId, "member.createGuest", { id, displayName: "Yoandry" }));
    const res = await api(`/clubs/${clubId}/invites`, { token: owner.token, body: { targetMemberId: id } });
    expect(res.status).toBe(201);
  });
});

describe("member.update", () => {
  it("cada uno cambia su nombre y apodo; quitar el apodo con null", async () => {
    const { clubId } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    await apply(raul.token, cmd(clubId, "member.update", { memberId: raul.memberId, displayName: "Raúl", nickname: "Rulo" }));
    await apply(raul.token, cmd(clubId, "member.update", { memberId: raul.memberId, nickname: null }));
    expect(await member(raul.memberId)).toMatchObject({ display_name: "Raúl", nickname: null });
  });

  it("un player no cambia el nombre de otro; el staff sí el de un sin cuenta; un admin el de cualquiera menos el owner", async () => {
    const { clubId } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const pepe = await addMember(clubId, "pepe", "player");
    const scorer = await addMember(clubId, "anotador", "scorer");
    const admin = await addMember(clubId, "jefe", "admin");
    const guest = await addGuest(clubId);
    const rename = (memberId: string) => cmd(clubId, "member.update", { memberId, displayName: "Otro nombre" });
    expect(await rejection(raul.token, rename(pepe.memberId))).toBe("forbidden");
    await apply(scorer.token, rename(guest));
    expect(await rejection(scorer.token, rename(pepe.memberId))).toBe("forbidden");
    await apply(admin.token, rename(pepe.memberId));
    expect(await rejection(admin.token, rename(await ownerMemberId(clubId)))).toBe("forbidden");
  });

  it("sin nada que cambiar: invalid_input", async () => {
    const { clubId, owner } = await activeClub();
    expect(await rejection(owner.token, cmd(clubId, "member.update", { memberId: await ownerMemberId(clubId) }))).toBe("invalid_input");
  });
});

describe("member.setRole", () => {
  it("el owner nombra admin; queda auditado", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    await apply(owner.token, cmd(clubId, "member.setRole", { memberId: raul.memberId, role: "admin" }));
    expect(await member(raul.memberId)).toMatchObject({ role: "admin" });
    expect(await auditActions(clubId)).toContain("member.setRole");
  });

  it("un admin no nombra admins; nadie se hace owner por aquí", async () => {
    const { clubId } = await activeClub();
    const admin = await addMember(clubId, "jefe", "admin");
    const raul = await addMember(clubId, "raul", "player");
    expect(await rejection(admin.token, cmd(clubId, "member.setRole", { memberId: raul.memberId, role: "admin" }))).toBe("forbidden");
    await apply(admin.token, cmd(clubId, "member.setRole", { memberId: raul.memberId, role: "scorer" }));
    expect(await rejection(admin.token, cmd(clubId, "member.setRole", { memberId: raul.memberId, role: "owner" }))).toBe("invalid_input");
  });

  it("a un miembro de otro servidor: not_found", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const pepe = await addMember(b.clubId, "pepe", "player");
    expect(await rejection(a.owner.token, cmd(a.clubId, "member.setRole", { memberId: pepe.memberId, role: "scorer" }))).toBe("not_found");
  });
});

describe("member.ban / unban / leave", () => {
  it("expulsar deja fuera al jugador: sus comandos siguientes dan not_found", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    await apply(owner.token, cmd(clubId, "member.ban", { memberId: raul.memberId }));
    expect(await member(raul.memberId)).toMatchObject({ status: "banned" });
    expect(await rejection(raul.token, cmd(clubId, "member.leave"))).toBe("not_found");
    expect(await auditActions(clubId)).toContain("member.ban");
  });

  it("un admin no expulsa a otro admin; nadie se expulsa a sí mismo", async () => {
    const { clubId, owner } = await activeClub();
    const admin = await addMember(clubId, "jefe", "admin");
    const other = await addMember(clubId, "otro", "admin");
    expect(await rejection(admin.token, cmd(clubId, "member.ban", { memberId: other.memberId }))).toBe("forbidden");
    expect(await rejection(owner.token, cmd(clubId, "member.ban", { memberId: await ownerMemberId(clubId) }))).toBe("forbidden");
  });

  it("quitar la expulsión lo deja como 'se fue': vuelve con una invitación", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    await apply(owner.token, cmd(clubId, "member.ban", { memberId: raul.memberId }));
    await apply(owner.token, cmd(clubId, "member.unban", { memberId: raul.memberId }));
    expect(await member(raul.memberId)).toMatchObject({ status: "left" });
    const code = (await api(`/clubs/${clubId}/invites`, { token: owner.token, body: {} })).body.invite.code;
    const back = await api(`/invites/${code}/accept`, { method: "POST", token: raul.token });
    expect(back.body.member.id).toBe(raul.memberId);
  });

  it("salir: el perfil se queda como 'left'; el owner no puede salir sin transferir", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    await apply(raul.token, cmd(clubId, "member.leave"));
    expect(await member(raul.memberId)).toMatchObject({ status: "left" });
    expect(await rejection(owner.token, cmd(clubId, "member.leave"))).toBe("owner_cannot_leave");
  });
});
