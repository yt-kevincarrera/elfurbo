import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addMember, auditActions } from "./fixtures";
import { apply, cmd, rejection } from "./sync-helpers";

async function seasons(clubId: string) {
  const { results } = await env.DB.prepare(
    "SELECT name, start_date, is_active, is_closed FROM seasons WHERE club_id = ? ORDER BY start_date",
  )
    .bind(clubId)
    .all();
  return results;
}

const year = String(new Date().getFullYear());

describe("temporadas", () => {
  it("al aprobar el servidor ya tiene la temporada del año en curso, activa", async () => {
    const { clubId } = await activeClub();
    expect(await seasons(clubId)).toEqual([{ name: year, start_date: `${year}-01-01`, is_active: 1, is_closed: 0 }]);
  });

  it("crear una nueva activa desactiva la anterior (solo una activa)", async () => {
    const { clubId, owner } = await activeClub();
    await apply(owner.token, cmd(clubId, "season.create", { id: crypto.randomUUID(), name: "Apertura", startDate: "2099-01-01", activate: true }));
    expect((await seasons(clubId)).map((s) => [s.name, s.is_active])).toEqual([
      [year, 0],
      ["Apertura", 1],
    ]);
  });

  it("activar, renombrar y cambiar la fecha", async () => {
    const { clubId, owner } = await activeClub();
    const id = crypto.randomUUID();
    await apply(owner.token, cmd(clubId, "season.create", { id, name: "Clausura", startDate: "2099-06-01" }));
    await apply(owner.token, cmd(clubId, "season.activate", { seasonId: id }));
    await apply(owner.token, cmd(clubId, "season.update", { seasonId: id, name: "Clausura 99", startDate: "2099-07-01" }));
    expect((await seasons(clubId)).at(-1)).toEqual({ name: "Clausura 99", start_date: "2099-07-01", is_active: 1, is_closed: 0 });
  });

  it("cerrar la activa la desactiva; una cerrada no se puede activar hasta reabrirla", async () => {
    const { clubId, owner } = await activeClub();
    const current = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ?").bind(clubId).first<{ id: string }>();
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: current!.id, closed: true }));
    expect((await seasons(clubId))[0]).toMatchObject({ is_active: 0, is_closed: 1 });
    expect(await rejection(owner.token, cmd(clubId, "season.activate", { seasonId: current!.id }))).toBe("invalid_state");
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: current!.id, closed: false }));
    await apply(owner.token, cmd(clubId, "season.activate", { seasonId: current!.id }));
    expect((await seasons(clubId))[0]).toMatchObject({ is_active: 1, is_closed: 0 });
  });

  it("borrar queda auditado", async () => {
    const { clubId, owner } = await activeClub();
    const id = crypto.randomUUID();
    await apply(owner.token, cmd(clubId, "season.create", { id, name: "Prueba", startDate: "2099-01-01" }));
    await apply(owner.token, cmd(clubId, "season.delete", { seasonId: id }));
    expect(await seasons(clubId)).toHaveLength(1);
    expect(await auditActions(clubId)).toContain("season.delete");
  });

  it("solo owner y admin; fecha en formato AAAA-MM-DD; la de otro servidor no existe", async () => {
    const { clubId, owner } = await activeClub();
    const scorer = await addMember(clubId, "anotador", "scorer");
    const create = (startDate: string) => cmd(clubId, "season.create", { id: crypto.randomUUID(), name: "X", startDate });
    expect(await rejection(scorer.token, create("2099-01-01"))).toBe("forbidden");
    expect(await rejection(owner.token, create("01/01/2099"))).toBe("invalid_input");
    expect(await rejection(owner.token, create("2099-02-30"))).toBe("invalid_input");
    const other = await activeClub("raul", "Otro");
    const foreign = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ?").bind(other.clubId).first<{ id: string }>();
    expect(await rejection(owner.token, cmd(clubId, "season.delete", { seasonId: foreign!.id }))).toBe("not_found");
  });
});
