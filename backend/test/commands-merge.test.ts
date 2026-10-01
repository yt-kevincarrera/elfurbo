import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, auditActions } from "./fixtures";
import { count, matchday, played, row, squad } from "./pachanga-helpers";
import { apply, cmd, pullAll, rejection } from "./sync-helpers";

/** Retoca updated_at para decidir quién es "más reciente" sin depender del reloj del test. */
async function touch(table: string, id: string, at: string) {
  await env.DB.prepare(`UPDATE ${table} SET updated_at = ? WHERE id = ?`).bind(at, id).run();
}

describe("matchday.merge (dos jornadas del mismo día creadas sin señal)", () => {
  it("todo pasa a la que se queda; si alguien tiene datos en las dos, gana el más reciente", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, admin } = await squad(clubId);
    const into = await matchday(owner.token, clubId);
    const from = await matchday(raul.token, clubId);
    await played(clubId, into, raul.token, pepe.token);
    await played(clubId, from, pepe.token);
    // Raúl reportó en las dos: la de `from` es más nueva.
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: into, goals: 1, assists: 0 }));
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: from, goals: 3, assists: 1 }));
    await touch("reports", `${into}:${raul.memberId}`, "2026-01-01T00:00:00.000Z");
    // Pepe solo reportó en `from`.
    await apply(pepe.token, cmd(clubId, "report.upsert", { matchdayId: from, goals: 0, assists: 2 }));

    await apply(admin.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    expect(await row("matchdays", from)).toBeNull();
    expect(await row("reports", `${into}:${raul.memberId}`)).toMatchObject({ goals: 3, assists: 1 });
    expect(await row("reports", `${into}:${pepe.memberId}`)).toMatchObject({ goals: 0, assists: 2 });
    expect(await count("reports", "matchday_id = ?", from)).toBe(0);
    expect(await count("attendance", "matchday_id = ?", from)).toBe(0);
    expect(await auditActions(clubId)).toContain("matchday.merge");
  });

  it("las confirmaciones siguen a su reporte: si gana el de `from`, se van las del otro", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, scorer, admin } = await squad(clubId);
    const into = await matchday(owner.token, clubId);
    const from = await matchday(owner.token, clubId);
    await played(clubId, into, raul.token, pepe.token);
    await played(clubId, from, raul.token, scorer.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: into, goals: 1, assists: 0 }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: into, memberId: raul.memberId }));
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: from, goals: 2, assists: 0 }));
    await apply(scorer.token, cmd(clubId, "report.confirm", { matchdayId: from, memberId: raul.memberId }));
    await touch("reports", `${into}:${raul.memberId}`, "2026-01-01T00:00:00.000Z");

    await apply(admin.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    const { results } = await env.DB.prepare("SELECT id FROM report_confirmations").all<{ id: string }>();
    expect(results.map((r) => r.id)).toEqual([`${into}:${raul.memberId}:${scorer.memberId}`]);
  });

  it("el pull manda lo de `from` como borrado y lo nuevo de `into` como cambiado", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, admin } = await squad(clubId);
    const into = await matchday(owner.token, clubId);
    const from = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: from, goals: 1, assists: 0 }));
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    await apply(admin.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.deletes.matchday).toEqual([from]);
    expect(next.deletes.report).toEqual([`${from}:${raul.memberId}`]);
    expect(next.upserts.report).toMatchObject([{ id: `${into}:${raul.memberId}`, matchdayId: into, goals: 1 }]);
  });

  it("un player une sus propias duplicadas si nadie más cargó datos en la que se borra", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const into = await matchday(raul.token, clubId);
    const from = await matchday(raul.token, clubId);
    await apply(raul.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    const again = await matchday(raul.token, clubId);
    await played(clubId, again, pepe.token);
    expect(await rejection(raul.token, cmd(clubId, "matchday.merge", { fromId: again, intoId: into }))).toBe("forbidden");
    const ownersOne = await matchday(owner.token, clubId);
    expect(await rejection(raul.token, cmd(clubId, "matchday.merge", { fromId: ownersOne, intoId: into }))).toBe("forbidden");
  });

  it("no se une una consigo misma ni una cerrada", async () => {
    const { clubId, owner } = await activeClub();
    const into = await matchday(owner.token, clubId);
    const from = await matchday(owner.token, clubId);
    expect(await rejection(owner.token, cmd(clubId, "matchday.merge", { fromId: into, intoId: into }))).toBe("invalid_input");
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: from, status: "closed" }));
    expect(await rejection(owner.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }))).toBe("matchday_closed");
  });
});
