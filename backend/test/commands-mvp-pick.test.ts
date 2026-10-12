import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { recomputeClub } from "../src/stats/job";
import { activeClub, auditActions, ownerMemberId } from "./fixtures";
import { hoursAgo, matchday, played, row, squad } from "./pachanga-helpers";
import { memberStats } from "./stats-helpers";
import { apply, cmd, pullAll, push, rejection } from "./sync-helpers";

/** Lleva la jornada al pasado: empezó hace `h` horas (por defecto, pasado el plazo de 72 h). */
async function startedAgo(id: string, h = 80) {
  await env.DB.prepare("UPDATE matchdays SET starts_at = ? WHERE id = ?").bind(hoursAgo(h), id).run();
}

/** Servidor con una jornada jugada por el dueño, Raúl y Pepe, sin votos. */
async function setup() {
  const { clubId, owner } = await activeClub();
  const people = await squad(clubId);
  const id = await matchday(owner.token, clubId);
  await played(clubId, id, owner.token, people.raul.token, people.pepe.token);
  return { clubId, owner, ownerId: await ownerMemberId(clubId), id, ...people };
}

const pick = (clubId: string, matchdayId: string, memberId: string | null) => cmd(clubId, "vote.pick", { matchdayId, memberId });

describe("MVP a dedo (vote.pick)", () => {
  it("solo owner o admin: el anotador y el jugador no", async () => {
    const { clubId, id, scorer, raul } = await setup();
    await startedAgo(id);
    expect(await rejection(scorer.token, pick(clubId, id, raul.memberId))).toBe("forbidden");
    expect(await rejection(raul.token, pick(clubId, id, raul.memberId))).toBe("forbidden");
  });

  it("con la votación abierta no se puede, ni cerrándola a mano antes del plazo, ni reabierta", async () => {
    const { clubId, owner, ownerId, id } = await setup();
    expect(await rejection(owner.token, pick(clubId, id, ownerId))).toBe("invalid_state");
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "closed" }));
    expect(await rejection(owner.token, pick(clubId, id, ownerId))).toBe("invalid_state");
    await startedAgo(id);
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "reopened" }));
    expect(await rejection(owner.token, pick(clubId, id, ownerId))).toBe("invalid_state");
  });

  it("pasado el plazo y sin votos: el admin elige (también a sí mismo), queda auditado y null lo quita", async () => {
    const { clubId, owner, ownerId, id, raul } = await setup();
    await startedAgo(id);
    await apply(owner.token, pick(clubId, id, ownerId));
    expect(await row("matchdays", id)).toMatchObject({ mvp_pick: ownerId, mvp_pick_by: ownerId });
    await apply(owner.token, pick(clubId, id, raul.memberId));
    expect(await row("matchdays", id)).toMatchObject({ mvp_pick: raul.memberId, mvp_pick_by: ownerId });
    await apply(owner.token, pick(clubId, id, null));
    expect(await row("matchdays", id)).toMatchObject({ mvp_pick: null, mvp_pick_by: null });
    expect((await auditActions(clubId)).filter((a) => a === "matchday.mvpPick")).toHaveLength(3);
    const { results } = await env.DB.prepare("SELECT summary FROM audit_log WHERE club_id = ? AND action = 'matchday.mvpPick' ORDER BY id")
      .bind(clubId)
      .all<{ summary: string }>();
    expect(results.map((r) => JSON.parse(r.summary))).toEqual([
      { memberId: ownerId, self: true },
      { memberId: raul.memberId, self: false },
      { memberId: null, self: false },
    ]);
  });

  it("un admin (no dueño) también puede, y puede elegirse a sí mismo si jugó", async () => {
    const { clubId, id, admin } = await setup();
    await played(clubId, id, admin.token);
    await startedAgo(id);
    await apply(admin.token, pick(clubId, id, admin.memberId));
    expect(await row("matchdays", id)).toMatchObject({ mvp_pick: admin.memberId, mvp_pick_by: admin.memberId });
  });

  it("cerrada a mano antes del plazo: no vale ni cuando el plazo pasa (nadie pudo votar)", async () => {
    const { clubId, owner, ownerId, id } = await setup();
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "closed" }));
    // Empezó hace 80 h y la cerraron a la hora de terminar: 70 h antes del plazo.
    await startedAgo(id);
    await env.DB.prepare("UPDATE audit_log SET at = ? WHERE entity_key = ? AND action = 'matchday.setStatus'").bind(hoursAgo(78), id).run();
    const [result] = await push(owner.token, pick(clubId, id, ownerId));
    expect(result).toMatchObject({ status: "rejected", code: "invalid_state", message: expect.stringContaining("La cerraron a mano") });
  });

  it("cerrada a mano después del plazo: vale", async () => {
    const { clubId, owner, ownerId, id } = await setup();
    await startedAgo(id);
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "closed" }));
    await apply(owner.token, pick(clubId, id, ownerId));
    expect(await row("matchdays", id)).toMatchObject({ mvp_pick: ownerId });
  });

  it("cerrada a mano antes, reabierta y vuelta a cerrar después del plazo: vale (cuenta el último cierre)", async () => {
    const { clubId, owner, ownerId, id } = await setup();
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "closed" }));
    await startedAgo(id);
    await env.DB.prepare("UPDATE audit_log SET at = ? WHERE entity_key = ? AND action = 'matchday.setStatus'").bind(hoursAgo(78), id).run();
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "reopened" }));
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "closed" }));
    await apply(owner.token, pick(clubId, id, ownerId));
    expect(await row("matchdays", id)).toMatchObject({ mvp_pick: ownerId });
  });

  it("si ya hay votos, decide la votación", async () => {
    const { clubId, owner, id, raul, pepe } = await setup();
    await apply(pepe.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: raul.memberId }));
    await startedAgo(id);
    expect(await rejection(owner.token, pick(clubId, id, pepe.memberId))).toBe("invalid_state");
  });

  it("solo a alguien que jugó", async () => {
    const { clubId, owner, id, guest, admin } = await setup();
    await startedAgo(id);
    expect(await rejection(owner.token, pick(clubId, id, guest))).toBe("not_present");
    expect(await rejection(admin.token, pick(clubId, id, admin.memberId))).toBe("not_present");
  });

  it("temporada cerrada o jornada cancelada: no", async () => {
    const { clubId, owner, ownerId, id } = await setup();
    const other = await matchday(owner.token, clubId);
    await played(clubId, other, owner.token);
    await startedAgo(id);
    await startedAgo(other);
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: other, status: "cancelled" }));
    expect(await rejection(owner.token, pick(clubId, other, ownerId))).toBe("matchday_not_played");
    const season = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ?").bind(clubId).first<{ id: string }>();
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: season!.id, closed: true }));
    expect(await rejection(owner.token, pick(clubId, id, ownerId))).toBe("season_closed");
  });

  it("viaja en el pull de la jornada y el job de estadísticas le cuenta el MVP", async () => {
    const { clubId, owner, ownerId, id, raul } = await setup();
    await startedAgo(id);
    await apply(owner.token, pick(clubId, id, raul.memberId));
    const c = (await pullAll(raul.token)).clubs[clubId]!;
    expect(c.upserts.matchday).toMatchObject([{ id, mvpPick: raul.memberId, mvpPickBy: ownerId }]);
    await recomputeClub(env.DB, clubId, new Date());
    const stats = await memberStats(clubId);
    expect(stats.filter((s) => s.member_id === raul.memberId).map((s) => s.mvps)).not.toHaveLength(0);
    expect(stats.filter((s) => s.member_id === raul.memberId).every((s) => s.mvps === 1)).toBe(true);
    expect(stats.filter((s) => s.member_id === ownerId).every((s) => s.mvps === 0)).toBe(true);
  });
});
