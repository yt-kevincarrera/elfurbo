import { describe, expect, it } from "vitest";
import { activeClub, addMember } from "./fixtures";
import { api } from "./helpers";

const audit = (clubId: string, token: string, query = "") => api(`/clubs/${clubId}/audit${query}`, { token });

describe("auditoría del servidor", () => {
  it("owner y admin la ven, lo más nuevo primero y con quién lo hizo", async () => {
    const { clubId, owner } = await activeClub();
    const admin = await addMember(clubId, "raul", "admin");
    await api(`/clubs/${clubId}/invites`, { token: owner.token, body: { role: "scorer" } });
    for (const who of [owner, admin]) {
      const res = await audit(clubId, who.token);
      expect(res.status).toBe(200);
      const first = res.body.entries[0];
      expect(first).toMatchObject({ action: "invite.create", entity: "invite", summary: { role: "scorer", maxUses: 1 } });
      expect(first.actor).toMatchObject({ username: "dueno" });
      expect(typeof first.id).toBe("number");
      expect(Date.parse(first.at)).not.toBeNaN();
    }
  });

  it("se pagina con ?before=", async () => {
    const { clubId, owner } = await activeClub();
    for (let i = 0; i < 3; i++) await api(`/clubs/${clubId}/invites`, { token: owner.token, body: {} });
    const page1 = await audit(clubId, owner.token, "?limit=2");
    expect(page1.body.entries).toHaveLength(2);
    expect(page1.body.next).toBe(page1.body.entries[1].id);
    const page2 = await audit(clubId, owner.token, `?limit=2&before=${page1.body.next}`);
    expect(page2.body.entries[0].id).toBeLessThan(page1.body.entries[1].id);
  });

  it("un limit o un before raros no rompen la ruta", async () => {
    const { clubId, owner } = await activeClub();
    for (const q of ["?limit=1.5", "?limit=abc", "?before=1e999", "?before=-3", "?limit=100000"]) {
      expect((await audit(clubId, owner.token, q)).status, q).toBe(200);
    }
  });

  it("un jugador o un anotador no la ven; alguien de otro servidor, ni que existe", async () => {
    const { clubId } = await activeClub();
    for (const role of ["player", "scorer"] as const) {
      const m = await addMember(clubId, `m.${role}`, role);
      expect((await audit(clubId, m.token)).status, role).toBe(403);
    }
    const other = await activeClub("otro", "Otro servidor");
    expect((await audit(clubId, other.owner.token)).status).toBe(404);
  });
});
