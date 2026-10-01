import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub } from "./fixtures";
import { hoursAgo, matchday, played, row, squad } from "./pachanga-helpers";
import { apply, cmd, rejection } from "./sync-helpers";

describe("rechazos y correcciones no se saltan", () => {
  it("report.loadFor no reescribe un reporte rechazado (ni el propio del anotador)", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 9, assists: 0 }));
    await apply(scorer.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 7, assists: 0 }));
    for (const m of [raul.memberId, scorer.memberId]) {
      await apply(admin.token, cmd(clubId, "report.decide", { matchdayId: id, memberId: m, decision: "rejected" }));
      expect(await rejection(scorer.token, cmd(clubId, "report.loadFor", { matchdayId: id, memberId: m, goals: 1, assists: 0 }))).toBe(
        "report_rejected",
      );
    }
    expect(await row("reports", `${id}:${scorer.memberId}`)).toMatchObject({ goals: 7, decision: "rejected" });
  });

  it("report.loadFor no pisa una corrección del admin; el admin sí puede recargarlo", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 5, assists: 0 }));
    await apply(admin.token, cmd(clubId, "report.correct", { matchdayId: id, memberId: raul.memberId, goals: 2, assists: 0 }));
    expect(await rejection(scorer.token, cmd(clubId, "report.loadFor", { matchdayId: id, memberId: raul.memberId, goals: 5, assists: 0 }))).toBe(
      "forbidden",
    );
    await apply(admin.token, cmd(clubId, "report.loadFor", { matchdayId: id, memberId: raul.memberId, goals: 3, assists: 0 }));
  });

  it("unir jornadas no reemplaza un reporte rechazado por uno más nuevo de la duplicada", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, admin } = await squad(clubId);
    const into = await matchday(owner.token, clubId);
    const from = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: into, goals: 9, assists: 0 }));
    await apply(admin.token, cmd(clubId, "report.decide", { matchdayId: into, memberId: raul.memberId, decision: "rejected" }));
    await env.DB.prepare("UPDATE reports SET updated_at = '2026-01-01T00:00:00.000Z' WHERE id = ?").bind(`${into}:${raul.memberId}`).run();
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: from, goals: 8, assists: 0 }));
    await apply(admin.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    expect(await row("reports", `${into}:${raul.memberId}`)).toMatchObject({ goals: 9, decision: "rejected" });
  });
});

describe("unir jornadas: la asistencia se une campo a campo", () => {
  it("un 'Voy' tardío de la duplicada no borra el 'jugó' que marcó el staff al pasar lista", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul, admin } = await squad(clubId);
    const into = await matchday(owner.token, clubId);
    const from = await matchday(owner.token, clubId);
    await apply(scorer.token, cmd(clubId, "attendance.rollCall", { matchdayId: into, entries: [{ memberId: raul.memberId, played: true }] }));
    await env.DB.prepare("UPDATE attendance SET updated_at = '2026-01-01T00:00:00.000Z' WHERE id = ?").bind(`${into}:${raul.memberId}`).run();
    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: from, intent: "yes" }, { clientAt: hoursAgo(5) }));
    await apply(admin.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    expect(await row("attendance", `${into}:${raul.memberId}`)).toMatchObject({ intent: "yes", played: 1, played_set_by: scorer.memberId });
  });
});

describe("editar una jornada respeta el cierre y los datos de otros", () => {
  it("cerrada (por plazo o a mano) o en una temporada cerrada: no se edita", async () => {
    const { clubId, owner } = await activeClub();
    const old = await matchday(owner.token, clubId, { startsAt: hoursAgo(80) });
    expect(await rejection(owner.token, cmd(clubId, "matchday.update", { matchdayId: old, startsAt: hoursAgo(3) }))).toBe("matchday_closed");
    const season = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ?").bind(clubId).first<{ id: string }>();
    const fresh = await matchday(owner.token, clubId);
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: season!.id, closed: true }));
    expect(await rejection(owner.token, cmd(clubId, "matchday.update", { matchdayId: fresh, notes: "x" }))).toBe("matchday_closed");
  });

  it("el player creador no mueve fecha, duración ni temporada si ya hay datos de otros (las notas sí)", async () => {
    const { clubId } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(raul.token, clubId);
    await played(clubId, id, pepe.token);
    expect(await rejection(raul.token, cmd(clubId, "matchday.update", { matchdayId: id, startsAt: hoursAgo(-24 * 30) }))).toBe("forbidden");
    expect(await rejection(raul.token, cmd(clubId, "matchday.update", { matchdayId: id, durationMinutes: 30 }))).toBe("forbidden");
    await apply(raul.token, cmd(clubId, "matchday.update", { matchdayId: id, notes: "Llegar temprano" }));
  });
});

describe("índices por servidor (la foto completa no recorre las tablas enteras)", () => {
  it.each(["matchdays", "attendance", "reports", "report_confirmations", "mvp_votes"])("%s usa un índice por club_id", async (table) => {
    const { results } = await env.DB.prepare(`EXPLAIN QUERY PLAN SELECT * FROM ${table} WHERE club_id = ?`).bind("c1").all<{ detail: string }>();
    expect(results.map((r) => r.detail).join(" ")).toMatch(/USING (COVERING )?INDEX/);
  });
});
