import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, auditActions } from "./fixtures";
import { count, hoursAgo, matchday, played, row, squad } from "./pachanga-helpers";
import { apply, cmd, pullAll, rejection } from "./sync-helpers";

describe("matchday.create", () => {
  it("cualquier miembro la crea en la temporada activa, con 120 min por defecto", async () => {
    const { clubId } = await activeClub();
    const { raul } = await squad(clubId);
    const id = crypto.randomUUID();
    await apply(raul.token, cmd(clubId, "matchday.create", { id, startsAt: "2026-10-10T14:00:00-04:00", place: "Cancha de 23" }));
    const active = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ? AND is_active = 1").bind(clubId).first<{ id: string }>();
    expect(await row("matchdays", id)).toMatchObject({
      season_id: active!.id,
      starts_at: "2026-10-10T18:00:00.000Z",
      duration_minutes: 0,
      place: "Cancha de 23",
      status: "scheduled",
      created_by: raul.memberId,
      teams: null,
    });
  });

  it("si el servidor dice 'solo staff', un player no puede", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    await apply(owner.token, cmd(clubId, "club.updateSettings", { matchdayCreators: "staff" }));
    expect(await rejection(raul.token, cmd(clubId, "matchday.create", { id: crypto.randomUUID(), startsAt: hoursAgo(-24) }))).toBe("forbidden");
  });

  it("sin temporada activa, o en una cerrada, no se crea", async () => {
    const { clubId, owner } = await activeClub();
    const season = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ?").bind(clubId).first<{ id: string }>();
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: season!.id, closed: true }));
    const create = (extra = {}) => cmd(clubId, "matchday.create", { id: crypto.randomUUID(), startsAt: hoursAgo(-24), ...extra });
    expect(await rejection(owner.token, create())).toBe("no_active_season");
    expect(await rejection(owner.token, create({ seasonId: season!.id }))).toBe("season_closed");
  });

  it("valida fecha y duración (opcional, 0 a 600 min)", async () => {
    const { clubId, owner } = await activeClub();
    const create = (extra: Record<string, unknown>) => cmd(clubId, "matchday.create", { id: crypto.randomUUID(), startsAt: hoursAgo(-24), ...extra });
    expect(await rejection(owner.token, create({ startsAt: "sábado" }))).toBe("invalid_input");
    expect(await rejection(owner.token, create({ durationMinutes: -1 }))).toBe("invalid_input");
    expect(await rejection(owner.token, create({ durationMinutes: 601 }))).toBe("invalid_input");
  });
});

describe("matchday.update / setStatus / delete", () => {
  it("el player que la creó la edita; otro player no; null borra el lugar", async () => {
    const { clubId } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(raul.token, clubId, { place: "Cancha vieja" });
    await apply(raul.token, cmd(clubId, "matchday.update", { matchdayId: id, place: null, notes: "Traer pelota" }));
    expect(await row("matchdays", id)).toMatchObject({ place: null, notes: "Traer pelota" });
    expect(await rejection(pepe.token, cmd(clubId, "matchday.update", { matchdayId: id, notes: "x" }))).toBe("forbidden");
  });

  it("el creador player la cancela si nadie más cargó datos; si ya hay datos de otros, solo el staff", async () => {
    const { clubId } = await activeClub();
    const { raul, pepe, scorer } = await squad(clubId);
    const id = await matchday(raul.token, clubId);
    await apply(raul.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "cancelled" }));
    await apply(raul.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "scheduled" }));
    await played(clubId, id, pepe.token);
    expect(await rejection(raul.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "cancelled" }))).toBe("forbidden");
    await apply(scorer.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "closed" }));
    expect(await auditActions(clubId)).toContain("matchday.setStatus");
  });

  it("borrar se lleva la asistencia, los reportes, las confirmaciones y los votos, y el pull los manda como borrados", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, raul.token, pepe.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 2, assists: 1 }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(pepe.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: raul.memberId }));
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;

    await apply(owner.token, cmd(clubId, "matchday.delete", { matchdayId: id }));
    for (const table of ["matchdays", "attendance", "reports", "report_confirmations", "mvp_votes"]) {
      expect(await count(table), table).toBe(0);
    }
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.deletes.matchday).toEqual([id]);
    expect(next.deletes.attendance).toHaveLength(2);
    expect(next.deletes.report).toEqual([`${id}:${raul.memberId}`]);
    expect(next.deletes.confirmation).toEqual([`${id}:${raul.memberId}:${pepe.memberId}`]);
    expect(next.deletes.vote).toEqual([`${id}:${pepe.memberId}`]);
  });
});

describe("teams.save", () => {
  it("el staff guarda equipos de miembros del servidor (también sin cuenta); null los quita", async () => {
    const { clubId } = await activeClub();
    const { scorer, raul, pepe, guest } = await squad(clubId);
    const id = await matchday(scorer.token, clubId, { startsAt: hoursAgo(-24) });
    await apply(scorer.token, cmd(clubId, "teams.save", { matchdayId: id, teams: { a: [raul.memberId], b: [pepe.memberId, guest] } }));
    expect(JSON.parse(String((await row("matchdays", id))!.teams))).toEqual({ a: [raul.memberId], b: [pepe.memberId, guest] });
    await apply(scorer.token, cmd(clubId, "teams.save", { matchdayId: id, teams: null }));
    expect((await row("matchdays", id))!.teams).toBeNull();
  });

  it("rechaza ids que no son miembros activos, y un player no puede", async () => {
    const { clubId } = await activeClub();
    const { scorer, raul } = await squad(clubId);
    const id = await matchday(scorer.token, clubId, { startsAt: hoursAgo(-24) });
    expect(await rejection(scorer.token, cmd(clubId, "teams.save", { matchdayId: id, teams: { a: ["inventado"], b: [] } }))).toBe("invalid_input");
    expect(await rejection(raul.token, cmd(clubId, "teams.save", { matchdayId: id, teams: { a: [], b: [] } }))).toBe("forbidden");
  });
});

describe("pull de la pachanga", () => {
  it("la foto trae jornadas, asistencia, reportes, confirmaciones y votos con su forma", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, raul.token, pepe.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 3, assists: 0, note: "Hat-trick" }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(pepe.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: raul.memberId }));
    const c = (await pullAll(pepe.token)).clubs[clubId]!;
    expect(c.upserts.matchday).toMatchObject([{ id, durationMinutes: 120, status: "scheduled", teams: null }]);
    expect(c.upserts.report).toMatchObject([{ memberId: raul.memberId, goals: 3, assists: 0, note: "Hat-trick", decision: null, loadedBy: raul.memberId }]);
    expect(c.upserts.attendance).toEqual(
      expect.arrayContaining([expect.objectContaining({ memberId: raul.memberId, played: true, intent: null })]),
    );
    expect(c.upserts.confirmation).toEqual([{ id: `${id}:${raul.memberId}:${pepe.memberId}`, matchdayId: id, memberId: raul.memberId, confirmerId: pepe.memberId }]);
    expect(c.upserts.vote).toEqual([{ id: `${id}:${pepe.memberId}`, matchdayId: id, voterId: pepe.memberId, votedFor: raul.memberId }]);
  });
});
