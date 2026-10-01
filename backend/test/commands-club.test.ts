import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions, ownerMemberId } from "./fixtures";
import { apply, cmd, pullAll, rejection } from "./sync-helpers";

async function settings(clubId: string) {
  const row = await env.DB.prepare("SELECT settings FROM clubs WHERE id = ?").bind(clubId).first<{ settings: string }>();
  return JSON.parse(row!.settings);
}

describe("club.updateSettings", () => {
  it("cambia solo lo que se manda y llega por el pull", async () => {
    const { clubId, owner } = await activeClub();
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    await apply(owner.token, cmd(clubId, "club.updateSettings", { reportValidation: "trust", closeAfterHours: 48 }));
    expect(await settings(clubId)).toEqual({
      matchdayCreators: "members",
      reportValidation: "trust",
      confirmationsNeeded: 2,
      closeAfterHours: 48,
      timezone: "America/Havana",
    });
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.upserts.club).toMatchObject([{ settings: { reportValidation: "trust", closeAfterHours: 48 } }]);
    expect(await auditActions(clubId)).toContain("club.updateSettings");
  });

  it("solo el owner", async () => {
    const { clubId } = await activeClub();
    const admin = await addMember(clubId, "jefe", "admin");
    expect(await rejection(admin.token, cmd(clubId, "club.updateSettings", { matchdayCreators: "staff" }))).toBe("forbidden");
  });

  it.each([
    [{ confirmationsNeeded: 0 }],
    [{ confirmationsNeeded: 6 }],
    [{ closeAfterHours: 12 }],
    [{ closeAfterHours: 200 }],
    [{ timezone: "Marte/Olympus" }],
    [{ matchdayCreators: "todos" }],
    [{ inventado: true }],
  ])("rechaza valores fuera de rango o claves desconocidas: %o", async (payload) => {
    const { clubId, owner } = await activeClub();
    expect(await rejection(owner.token, cmd(clubId, "club.updateSettings", payload))).toBe("invalid_input");
  });

  it("acepta otra zona horaria válida", async () => {
    const { clubId, owner } = await activeClub();
    await apply(owner.token, cmd(clubId, "club.updateSettings", { timezone: "Europe/Madrid" }));
    expect((await settings(clubId)).timezone).toBe("Europe/Madrid");
  });
});

describe("club.transferOwnership", () => {
  it("el owner pasa la propiedad a otro y se queda como admin", async () => {
    const { clubId, owner } = await activeClub();
    const oldOwner = await ownerMemberId(clubId);
    const raul = await addMember(clubId, "raul", "player");
    await apply(owner.token, cmd(clubId, "club.transferOwnership", { memberId: raul.memberId }));
    const roles = await env.DB.prepare("SELECT id, role FROM members WHERE id IN (?, ?)").bind(oldOwner, raul.memberId).all();
    expect(roles.results).toEqual(expect.arrayContaining([{ id: oldOwner, role: "admin" }, { id: raul.memberId, role: "owner" }]));
    expect(await auditActions(clubId)).toContain("club.transfer");
    // El antiguo dueño ya puede salir; el nuevo, no.
    await apply(owner.token, cmd(clubId, "member.leave"));
    expect(await rejection(raul.token, cmd(clubId, "member.leave"))).toBe("owner_cannot_leave");
  });

  it("no a un sin cuenta; y un admin no puede transferir", async () => {
    const { clubId, owner } = await activeClub();
    const guest = await addGuest(clubId);
    const admin = await addMember(clubId, "jefe", "admin");
    expect(await rejection(owner.token, cmd(clubId, "club.transferOwnership", { memberId: guest }))).toBe("invalid_input");
    expect(await rejection(admin.token, cmd(clubId, "club.transferOwnership", { memberId: admin.memberId }))).toBe("forbidden");
  });
});
