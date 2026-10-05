import { describe, expect, it } from "vitest";
import { activeClub, auditActions } from "./fixtures";
import { count, hoursAgo, matchday, played, row, squad } from "./pachanga-helpers";
import { apply, cmd, rejection } from "./sync-helpers";

describe("reportes", () => {
  it("mi reporte cuenta como 'jugué'; antes de jugarse no se puede", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const future = await matchday(owner.token, clubId, { startsAt: hoursAgo(-2) });
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: future, goals: 1, assists: 0 }))).toBe("matchday_not_played");
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 2, assists: 1, note: "Golazo" }));
    expect(await row("reports", `${id}:${raul.memberId}`)).toMatchObject({ goals: 2, assists: 1, note: "Golazo", loaded_by: raul.memberId, decision: null });
    expect(await row("attendance", `${id}:${raul.memberId}`)).toMatchObject({ played: 1 });
  });

  it("valida 0 a 30 goles y asistencias", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 31, assists: 0 }))).toBe("invalid_input");
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: -1, assists: 0 }))).toBe("invalid_input");
  });

  it("confirman los compañeros que jugaron; uno mismo no; confirmar dos veces no duplica", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 0 }));
    expect(await rejection(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }))).toBe("not_present");
    await played(clubId, id, pepe.token);
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    expect(await count("report_confirmations")).toBe(1);
    expect(await rejection(raul.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }))).toBe("forbidden");
    expect(await rejection(admin.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }))).toBe("not_present");
    await apply(pepe.token, cmd(clubId, "report.unconfirm", { matchdayId: id, memberId: raul.memberId }));
    expect(await count("report_confirmations")).toBe(0);
  });

  it("editar mi reporte lo vuelve pendiente: se van las confirmaciones y la decisión", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, pepe.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 0 }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(admin.token, cmd(clubId, "report.decide", { matchdayId: id, memberId: raul.memberId, decision: "confirmed" }));
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 4, assists: 0 }));
    expect(await row("reports", `${id}:${raul.memberId}`)).toMatchObject({ goals: 4, decision: null });
    expect(await count("report_confirmations")).toBe(0);
  });

  it("rechazo definitivo: el autor ya no lo edita ni lo borra; el admin puede quitar la decisión", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 9, assists: 0 }));
    await apply(admin.token, cmd(clubId, "report.decide", { matchdayId: id, memberId: raul.memberId, decision: "rejected" }));
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 8, assists: 0 }))).toBe("report_rejected");
    expect(await rejection(raul.token, cmd(clubId, "report.delete", { matchdayId: id }))).toBe("report_rejected");
    await apply(admin.token, cmd(clubId, "report.decide", { matchdayId: id, memberId: raul.memberId, decision: null }));
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 0 }));
    expect(await auditActions(clubId)).toContain("report.decide");
  });

  it("corregir: queda confirmado y marcado; solo owner o admin", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, scorer, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 5, assists: 0 }));
    expect(await rejection(scorer.token, cmd(clubId, "report.correct", { matchdayId: id, memberId: raul.memberId, goals: 2, assists: 1 }))).toBe(
      "forbidden",
    );
    await apply(admin.token, cmd(clubId, "report.correct", { matchdayId: id, memberId: raul.memberId, goals: 2, assists: 1 }));
    expect(await row("reports", `${id}:${raul.memberId}`)).toMatchObject({ goals: 2, assists: 1, decision: "confirmed", corrected_by: admin.memberId });
  });

  it("el staff carga el reporte de un sin cuenta (y queda como presente)", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul, guest } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(scorer.token, cmd(clubId, "report.loadFor", { matchdayId: id, memberId: guest, goals: 1, assists: 2 }));
    // Lo que pone el staff queda confirmado en el reporte: no depende del rol que tenga después.
    expect(await row("reports", `${id}:${guest}`)).toMatchObject({ goals: 1, assists: 2, loaded_by: scorer.memberId, decision: "confirmed" });
    await apply(scorer.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 0 }));
    expect(await row("reports", `${id}:${scorer.memberId}`)).toMatchObject({ decision: "confirmed" });
    expect(await row("attendance", `${id}:${guest}`)).toMatchObject({ played: 1 });
    expect(await rejection(raul.token, cmd(clubId, "report.loadFor", { matchdayId: id, memberId: guest, goals: 1, assists: 0 }))).toBe("forbidden");
    expect(await auditActions(clubId)).toContain("report.loadFor");
  });

  it("borrar mi reporte se lleva sus confirmaciones", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, pepe.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 0 }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(raul.token, cmd(clubId, "report.delete", { matchdayId: id }));
    expect(await count("reports")).toBe(0);
    expect(await count("report_confirmations")).toBe(0);
  });

  it("reportar hecho a tiempo sin señal (a las 70 h) y subido a las 80 h: se acepta", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const id = await matchday(owner.token, clubId, { startsAt: hoursAgo(80) });
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 1 }, { clientAt: hoursAgo(10) }));
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 2, assists: 1 }))).toBe("matchday_closed");
  });
});

describe("votos de MVP", () => {
  it("votan los que jugaron por otro que jugó (también sin cuenta); cambiar el voto lo reemplaza", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul, pepe, guest } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, raul.token, pepe.token);
    await apply(scorer.token, cmd(clubId, "attendance.rollCall", { matchdayId: id, entries: [{ memberId: guest, played: true }] }));
    await apply(raul.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: pepe.memberId }));
    await apply(raul.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: guest }));
    expect(await row("mvp_votes", `${id}:${raul.memberId}`)).toMatchObject({ voted_for: guest });
    expect(await count("mvp_votes")).toBe(1);
    await apply(raul.token, cmd(clubId, "vote.clear", { matchdayId: id }));
    expect(await count("mvp_votes")).toBe(0);
  });

  it("no a uno mismo, ni si alguno de los dos no jugó, ni antes de jugarse", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, raul.token);
    expect(await rejection(raul.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: raul.memberId }))).toBe("invalid_input");
    expect(await rejection(raul.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: pepe.memberId }))).toBe("not_present");
    expect(await rejection(admin.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: raul.memberId }))).toBe("not_present");
    const future = await matchday(owner.token, clubId, { startsAt: hoursAgo(-3) });
    expect(await rejection(raul.token, cmd(clubId, "vote.cast", { matchdayId: future, votedFor: pepe.memberId }))).toBe("matchday_not_played");
  });
});
