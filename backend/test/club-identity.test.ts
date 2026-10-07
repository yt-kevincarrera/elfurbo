import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addMember, auditActions } from "./fixtures";
import { api, register } from "./helpers";
import { apply, cmd, pullAll, rejection } from "./sync-helpers";

const post = (path: string, token: string, body?: unknown) => api(path, { method: "POST", token, body });

async function clubRow(clubId: string) {
  return env.DB.prepare("SELECT name, description, province, city, color, visibility, official, delisted, settings FROM clubs WHERE id = ?")
    .bind(clubId)
    .first<Record<string, unknown>>();
}

describe("identidad del servidor (2.0)", () => {
  it("un servidor nuevo es un grupo privado, sin provincia y con el color 0, y así llega por el pull y /me", async () => {
    const { clubId, owner } = await activeClub();
    const club = (await pullAll(owner.token)).clubs[clubId]!.upserts.club![0]!;
    expect(club).toMatchObject({
      kind: "group",
      visibility: "private",
      official: false,
      province: null,
      city: null,
      color: 0,
      hostClubId: null,
      settings: { joinPolicy: "request", shareStats: true },
    });
    const me = await api("/me", { token: owner.token });
    expect(me.body.clubs[0]).toMatchObject({ id: clubId, kind: "group", color: 0, official: false, role: "owner" });
  });

  it("club.updateProfile cambia solo lo que se manda, se audita y llega por el pull", async () => {
    const { clubId, owner } = await activeClub();
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    await apply(
      owner.token,
      cmd(clubId, "club.updateProfile", { name: "  Los Pinos  ", province: "hab", city: " Playa ", color: 3 }),
    );
    expect(await clubRow(clubId)).toMatchObject({
      name: "Los Pinos",
      description: "",
      province: "hab",
      city: "Playa",
      color: 3,
    });
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.upserts.club).toMatchObject([{ name: "Los Pinos", province: "hab", city: "Playa", color: 3 }]);
    expect(await auditActions(clubId)).toContain("club.updateProfile");

    // Vaciar la ciudad y quitar la provincia.
    await apply(owner.token, cmd(clubId, "club.updateProfile", { city: "  ", province: null, description: "Los sábados" }));
    expect(await clubRow(clubId)).toMatchObject({ province: null, city: null, description: "Los sábados" });
  });

  it.each([
    [{}],
    [{ name: "ab" }],
    [{ name: "x".repeat(41) }],
    [{ description: "x".repeat(201) }],
    [{ province: "marte" }],
    [{ city: "x".repeat(41) }],
    [{ color: 8 }],
    [{ color: -1 }],
    [{ kind: "tournament" }],
    [{ official: true }],
  ])("club.updateProfile rechaza %o", async (payload) => {
    const { clubId, owner } = await activeClub();
    expect(await rejection(owner.token, cmd(clubId, "club.updateProfile", payload))).toBe("invalid_input");
  });

  it("club.updateProfile y club.setVisibility: solo el owner", async () => {
    const { clubId } = await activeClub();
    const admin = await addMember(clubId, "jefe", "admin");
    expect(await rejection(admin.token, cmd(clubId, "club.updateProfile", { color: 1 }))).toBe("forbidden");
    expect(await rejection(admin.token, cmd(clubId, "club.setVisibility", { visibility: "public" }))).toBe("forbidden");
  });

  it("club.setVisibility: público y abierto, luego privado conservando cómo se entra", async () => {
    const { clubId, owner } = await activeClub();
    await apply(owner.token, cmd(clubId, "club.setVisibility", { visibility: "public", joinPolicy: "open" }));
    let row = await clubRow(clubId);
    expect(row).toMatchObject({ visibility: "public" });
    expect(JSON.parse(String(row!.settings))).toMatchObject({ joinPolicy: "open" });
    await apply(owner.token, cmd(clubId, "club.setVisibility", { visibility: "private" }));
    row = await clubRow(clubId);
    expect(row).toMatchObject({ visibility: "private" });
    expect(JSON.parse(String(row!.settings))).toMatchObject({ joinPolicy: "open" });
    expect(await auditActions(clubId)).toContain("club.setVisibility");
    expect(await rejection(owner.token, cmd(clubId, "club.setVisibility", { visibility: "secreto" }))).toBe("invalid_input");
  });

  it("club.updateSettings acepta shareStats", async () => {
    const { clubId, owner } = await activeClub();
    await apply(owner.token, cmd(clubId, "club.updateSettings", { shareStats: false }));
    expect(JSON.parse(String((await clubRow(clubId))!.settings))).toMatchObject({ shareStats: false });
  });
});

describe("superadmin: oficial y directorio", () => {
  it("marca y desmarca como oficial, con su auditoría y un cambio para el pull", async () => {
    const { clubId, owner, admin } = await activeClub();
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    const res = await post(`/admin/clubs/${clubId}/official`, admin.token, { official: true, note: "Liga del barrio" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ club: { id: clubId, official: true } });
    expect((await clubRow(clubId))!.official).toBe(1);
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.upserts.club).toMatchObject([{ official: true }]);
    expect((await api("/me", { token: owner.token })).body.clubs[0].official).toBe(true);

    await post(`/admin/clubs/${clubId}/official`, admin.token, { official: false });
    expect((await clubRow(clubId))!.official).toBe(0);
    expect(await auditActions(clubId)).toEqual(expect.arrayContaining(["club.official", "club.unofficial"]));
  });

  it("sacarlo del directorio lo pasa a privado y el dueño ya no lo puede hacer público hasta que se permita otra vez", async () => {
    const { clubId, owner, admin } = await activeClub();
    await apply(owner.token, cmd(clubId, "club.setVisibility", { visibility: "public" }));
    expect((await post(`/admin/clubs/${clubId}/delist`, admin.token, { delisted: true, note: "Nombre feo" })).status).toBe(200);
    expect(await clubRow(clubId)).toMatchObject({ visibility: "private", delisted: 1 });
    expect(await rejection(owner.token, cmd(clubId, "club.setVisibility", { visibility: "public" }))).toBe("club_delisted");
    // Privado sí puede seguir siendo.
    await apply(owner.token, cmd(clubId, "club.setVisibility", { visibility: "private", joinPolicy: "request" }));

    await post(`/admin/clubs/${clubId}/delist`, admin.token, { delisted: false });
    await apply(owner.token, cmd(clubId, "club.setVisibility", { visibility: "public" }));
    expect(await auditActions(clubId)).toEqual(expect.arrayContaining(["club.delist", "club.relist"]));
  });

  it("la lista y el detalle del superadmin dicen si es oficial, público o está fuera del directorio", async () => {
    const { clubId, admin } = await activeClub();
    await post(`/admin/clubs/${clubId}/official`, admin.token, { official: true });
    const list = await api("/admin/clubs", { token: admin.token });
    expect(list.body.clubs[0]).toMatchObject({ id: clubId, kind: "group", visibility: "private", official: true, delisted: false });
    const detail = await api(`/admin/clubs/${clubId}`, { token: admin.token });
    expect(detail.body.club).toMatchObject({ kind: "group", official: true, color: 0, province: null });
  });

  it("solo el superadmin; y un servidor pendiente no se marca", async () => {
    const { clubId, owner, admin } = await activeClub();
    const other = await register("cualquiera");
    for (const token of [owner.token, other.token]) {
      expect((await post(`/admin/clubs/${clubId}/official`, token, { official: true })).status).toBe(403);
      expect((await post(`/admin/clubs/${clubId}/delist`, token, { delisted: true })).status).toBe(403);
    }
    const pending = (await post("/clubs", other.token, { name: "Pendiente" })).body.club.id as string;
    expect((await post(`/admin/clubs/${pending}/official`, admin.token, { official: true })).status).toBe(409);
    expect((await post(`/admin/clubs/${clubId}/official`, admin.token, { official: "si" })).status).toBe(400);
  });
});
