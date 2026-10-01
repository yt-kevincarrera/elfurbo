import { describe, expect, it } from "vitest";
import { activeClub } from "./fixtures";
import { hoursAgo, matchday, row, squad } from "./pachanga-helpers";
import { apply, cmd, rejection } from "./sync-helpers";

describe("asistencia", () => {
  it("antes de jugarse: Voy / Quizás / No voy, y se puede quitar con null", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const id = await matchday(owner.token, clubId, { startsAt: hoursAgo(-48) });
    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }));
    expect(await row("attendance", `${id}:${raul.memberId}`)).toMatchObject({ intent: "yes", played: null });
    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: null }));
    expect(await row("attendance", `${id}:${raul.memberId}`)).toMatchObject({ intent: null });
  });

  it("ya jugada, la intención no se cambia; pero si se marcó antes sin señal y llega tarde, vale", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(owner.token, clubId); // empezó hace 3 h, terminó hace 1
    expect(await rejection(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }))).toBe("matchday_already_played");
    await apply(pepe.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }, { clientAt: hoursAgo(5) }));
  });

  it("'Jugué' solo cuando terminó, con la hora del servidor", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const future = await matchday(owner.token, clubId, { startsAt: hoursAgo(-1) });
    expect(await rejection(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: future, played: true }))).toBe("matchday_not_played");
    const past = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: past, played: true }));
    expect(await row("attendance", `${past}:${raul.memberId}`)).toMatchObject({ played: 1, played_set_by: raul.memberId });
  });

  it("pasar lista: el staff marca a todos, incluido el que no tiene cuenta, sin tocar su intención", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul, pepe, guest } = await squad(clubId);
    const id = await matchday(owner.token, clubId, { startsAt: hoursAgo(-1), durationMinutes: 30 });
    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }));
    const later = await matchday(owner.token, clubId);
    await apply(
      scorer.token,
      cmd(clubId, "attendance.rollCall", {
        matchdayId: later,
        entries: [
          { memberId: raul.memberId, played: true },
          { memberId: pepe.memberId, played: false },
          { memberId: guest, played: true },
        ],
      }),
    );
    expect(await row("attendance", `${later}:${guest}`)).toMatchObject({ played: 1, played_set_by: scorer.memberId });
    expect(await row("attendance", `${later}:${pepe.memberId}`)).toMatchObject({ played: 0 });
    expect(await rejection(raul.token, cmd(clubId, "attendance.rollCall", { matchdayId: later, entries: [{ memberId: raul.memberId, played: true }] }))).toBe("forbidden");
  });

  it("cerrada no acepta nada: a mano siempre; por plazo, según la hora del teléfono", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const old = await matchday(owner.token, clubId, { startsAt: hoursAgo(80) }); // más de 72 h
    expect(await rejection(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: old, played: true }))).toBe("matchday_closed");
    // Lo marcó sin señal a las 70 h (dentro del plazo) y llega ahora: vale.
    await apply(pepe.token, cmd(clubId, "attendance.setPlayed", { matchdayId: old, played: true }, { clientAt: hoursAgo(10) }));

    const fresh = await matchday(owner.token, clubId);
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: fresh, status: "closed" }));
    expect(await rejection(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: fresh, played: true }, { clientAt: hoursAgo(1) }))).toBe(
      "matchday_closed",
    );
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: old, status: "reopened" }));
    await apply(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: old, played: true }));
  });

  it("una jornada de otro servidor no existe", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul2", "Otro");
    const id = await matchday(b.owner.token, b.clubId);
    expect(await rejection(a.owner.token, cmd(a.clubId, "attendance.setPlayed", { matchdayId: id, played: true }))).toBe("not_found");
  });
});
