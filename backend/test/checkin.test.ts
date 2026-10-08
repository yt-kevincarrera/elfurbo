import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import fixtures from "../../shared-fixtures/checkin.json";
import { checkinCode, checkinValid } from "../src/rules/checkin";
import { recomputeClub } from "../src/stats/job";
import { activeClub } from "./fixtures";
import { api } from "./helpers";
import { hoursAgo, matchday, row, squad } from "./pachanga-helpers";
import { apply, cmd, pullAll, rejection } from "./sync-helpers";

describe("shared-fixtures/checkin.json (los mismos casos que ejecuta la app en Dart)", () => {
  it.each(fixtures.cases)("$name", async (c) => {
    expect(await checkinCode(c.secret, new Date(c.at))).toBe(c.code);
  });

  it("vale la ventana de al lado, no la siguiente", async () => {
    const c = fixtures.cases[2]!;
    const at = new Date(c.at);
    expect(await checkinValid(c.secret, new Date(at.getTime() + 299_000), c.code)).toBe(true);
    expect(await checkinValid(c.secret, new Date(at.getTime() - 300_000), c.code)).toBe(true);
    expect(await checkinValid(c.secret, new Date(at.getTime() + 600_000), c.code)).toBe(false);
  });
});

async function secretOf(token: string, clubId: string) {
  const res = await api(`/clubs/${clubId}/checkin-secret`, { token });
  expect(res.status).toBe(200);
  return res.body.secret as string;
}

describe("código de asistencia", () => {
  it("el secreto: solo el staff, se crea una vez y no viaja en el pull", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul } = await squad(clubId);
    const first = await secretOf(owner.token, clubId);
    expect(first).toMatch(/^[0-9a-f]{64}$/);
    expect(await secretOf(scorer.token, clubId)).toBe(first);
    expect((await api(`/clubs/${clubId}/checkin-secret`, { token: raul.token })).status).toBe(403);
    expect(JSON.stringify(await pullAll(raul.token))).not.toContain(first);
  });

  it("'Estoy aquí' con el código de ahora marca que jugó y que lo comprobó", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const secret = await secretOf(owner.token, clubId);
    const id = await matchday(owner.token, clubId, { startsAt: hoursAgo(0.5) });
    const code = await checkinCode(secret, new Date());
    await apply(raul.token, cmd(clubId, "attendance.checkIn", { matchdayId: id, code }));
    const r = await row("attendance", `${id}:${raul.memberId}`);
    expect(r).toMatchObject({ played: 1, played_set_by: raul.memberId });
    expect(r!.checked_in_at).not.toBeNull();
    const wrong = code === "000000" ? "111111" : "000000";
    expect(await rejection(pepe.token, cmd(clubId, "attendance.checkIn", { matchdayId: id, code: wrong }))).toBe("invalid_checkin_code");
    // Escrito sin señal hace 10 minutos: se juzga con la hora del teléfono.
    const before = new Date(Date.now() - 10 * 60_000);
    await apply(pepe.token, cmd(clubId, "attendance.checkIn", { matchdayId: id, code: await checkinCode(secret, before) }, { clientAt: before.toISOString() }));
  });

  it("solo cerca de la hora de la jornada", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const secret = await secretOf(owner.token, clubId);
    const far = await matchday(owner.token, clubId, { startsAt: hoursAgo(-5) });
    const code = await checkinCode(secret, new Date());
    expect(await rejection(raul.token, cmd(clubId, "attendance.checkIn", { matchdayId: far, code }))).toBe("checkin_closed");
  });

  it("cuenta en las estadísticas del jugador", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const secret = await secretOf(owner.token, clubId);
    const id = await matchday(owner.token, clubId, { startsAt: hoursAgo(2.5) });
    await apply(raul.token, cmd(clubId, "attendance.checkIn", { matchdayId: id, code: await checkinCode(secret, new Date()) }));
    await recomputeClub(env.DB, clubId, new Date());
    const stats = await env.DB.prepare("SELECT played, checkins FROM member_stats WHERE club_id = ? AND member_id = ?")
      .bind(clubId, raul.memberId)
      .first();
    expect(stats).toMatchObject({ played: 1, checkins: 1 });
  });
});

describe("cupo y lista de espera", () => {
  it("la jornada toma el cupo del servidor; 'Voy' guarda el turno y bajarse lo pierde", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    await apply(owner.token, cmd(clubId, "club.updateSettings", { maxPlayers: 12 }));
    const id = await matchday(owner.token, clubId, { startsAt: hoursAgo(-24) });
    expect(await row("matchdays", id)).toMatchObject({ max_players: 12 });
    await apply(owner.token, cmd(clubId, "matchday.update", { matchdayId: id, maxPlayers: 0 }));
    expect(await row("matchdays", id)).toMatchObject({ max_players: 0 });

    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }));
    const first = (await row("attendance", `${id}:${raul.memberId}`))!.intent_at;
    expect(first).not.toBeNull();
    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }));
    expect((await row("attendance", `${id}:${raul.memberId}`))!.intent_at).toBe(first);
    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "maybe" }));
    expect((await row("attendance", `${id}:${raul.memberId}`))!.intent_at).toBeNull();
  });
});
