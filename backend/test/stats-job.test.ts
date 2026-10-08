import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { recomputeClub, recomputeStats, staleClubs } from "../src/stats/job";
import { activeClub, ownerMemberId } from "./fixtures";
import { api } from "./helpers";
import { daysAgo, memberStats, metrics, seedMatchday, seedMembers, seedWeekly, activeSeason } from "./stats-helpers";
import { apply, cmd } from "./sync-helpers";

const post = (path: string, token: string, body?: unknown) => api(path, { method: "POST", token, body });

describe("job de estadísticas", () => {
  it("un servidor recién aprobado es Nuevo, sin estadísticas", async () => {
    const { clubId, owner } = await activeClub();
    expect(await recomputeStats(env.DB, new Date())).toContain(clubId);
    expect(await metrics(clubId)).toMatchObject({ tier: "new", active_players: 0, last_played_at: null });
    expect(await memberStats(clubId)).toEqual([]);
    expect((await api("/me", { token: owner.token })).body.clubs[0].tier).toBe("new");
  });

  it("12 semanas de jornadas de 10 con cuenta, confirmadas por el staff: Verificado, con sus estadísticas por temporada", async () => {
    const { clubId, owner } = await activeClub();
    const staff = await ownerMemberId(clubId);
    const players = await seedMembers(clubId, 10);
    const season = await seedWeekly(clubId, players, 12, staff);
    await recomputeClub(env.DB, clubId, new Date());

    const m = await metrics(clubId);
    expect(m).toMatchObject({ tier: "verified", active_players: 10, play_days: expect.any(String) });
    expect(JSON.parse(String(m!.signals))).toMatchObject({ matchdays90: 12, avgPlayers: 10, accountsShare: 1, staffShare: 1 });
    expect(Number(m!.score)).toBeGreaterThanOrEqual(70);
    expect(JSON.parse(String(m!.play_days))).toHaveLength(1);

    const stats = await memberStats(clubId);
    expect(stats).toHaveLength(10);
    expect(stats[0]).toMatchObject({ period_id: season, played: 12, goals: 12, best_streak: 12, reports: 12, flag: 0 });

    // /me y la ruta de prestigio.
    expect((await api("/me", { token: owner.token })).body.clubs[0].tier).toBe("verified");
    const prestige = await api(`/clubs/${clubId}/prestige`, { token: owner.token });
    expect(prestige.status).toBe(200);
    expect(prestige.body).toMatchObject({ tier: "verified", computedAt: expect.any(String), newReason: null });
    const network = prestige.body.parts.find((p: { key: string }) => p.key === "network");
    expect(network).toMatchObject({ points: 0, max: 15, hint: expect.stringContaining("otros servidores") });
  });

  it('"Confiando" no pasa de Establecido', async () => {
    const { clubId, owner } = await activeClub();
    const staff = await ownerMemberId(clubId);
    await seedWeekly(clubId, await seedMembers(clubId, 10), 12, staff);
    await apply(owner.token, cmd(clubId, "club.updateSettings", { reportValidation: "trust" }));
    await recomputeClub(env.DB, clubId, new Date());
    expect(await metrics(clubId)).toMatchObject({ tier: "established" });
    const prestige = (await api(`/clubs/${clubId}/prestige`, { token: owner.token })).body;
    expect(prestige.parts.find((p: { key: string }) => p.key === "validation").hint).toContain("Confiando");
  });

  it("goleadas imposibles penalizan, y quien promedia el doble con más de 4 queda marcado", async () => {
    const { clubId } = await activeClub();
    const staff = await ownerMemberId(clubId);
    const players = await seedMembers(clubId, 6);
    const season = await activeSeason(clubId);
    for (let w = 5; w >= 1; w--) {
      await seedMatchday(
        clubId,
        season,
        daysAgo(w * 7 + 30),
        players.map((member, i) => ({ member, goals: i === 0 ? 9 : 1 })),
        staff,
      );
    }
    await recomputeClub(env.DB, clubId, new Date());
    const signals = JSON.parse(String((await metrics(clubId))!.signals));
    expect(signals.goalsPerPresence).toBeCloseTo(14 / 6);
    const stats = await memberStats(clubId);
    expect(stats.find((s) => s.member_id === players[0])).toMatchObject({ goals: 45, flag: 1 });
    expect(stats.find((s) => s.member_id === players[1])).toMatchObject({ flag: 0 });
    const prestige = (await api(`/clubs/${clubId}/prestige`, { token: (await activeClubOwner(clubId))! })).body;
    expect(prestige.parts.find((p: { key: string }) => p.key === "goals")).toMatchObject({ points: -5 });
  });

  it("al cerrar una temporada su nivel se congela; la abierta sigue al del servidor", async () => {
    const { clubId, owner, admin } = await activeClub();
    const staff = await ownerMemberId(clubId);
    const old = await seedWeekly(clubId, await seedMembers(clubId, 4), 6, staff);
    await recomputeClub(env.DB, clubId, new Date());
    await apply(owner.token, cmd(clubId, "season.create", { id: crypto.randomUUID(), name: "Nueva", startDate: "2026-11-01", activate: true }));
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: old, closed: true }));
    await recomputeClub(env.DB, clubId, new Date());
    const tierOf = async (period: string) =>
      (await env.DB.prepare("SELECT tier, frozen_at FROM period_tiers WHERE club_id = ? AND period_id = ?").bind(clubId, period).first())!;
    const frozen = await tierOf(old);
    expect(frozen.frozen_at).not.toBeNull();

    // Ahora lo hacen oficial: la temporada cerrada se queda como estaba; la nueva, oficial.
    await post(`/admin/clubs/${clubId}/official`, admin.token, { official: true });
    await recomputeClub(env.DB, clubId, new Date());
    expect((await tierOf(old)).tier).toBe(frozen.tier);
    const current = await activeSeason(clubId);
    expect(await tierOf(current)).toMatchObject({ tier: "official", frozen_at: null });

    // Reabrirla la descongela.
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: old, closed: false }));
    await recomputeClub(env.DB, clubId, new Date());
    expect(await tierOf(old)).toMatchObject({ tier: "official", frozen_at: null });
  });

  it("solo recalcula lo que cambió (o lo de hace más de un día) y respeta el máximo por pasada", async () => {
    const a = await activeClub("dueno.a", "Uno");
    const b = await activeClub("dueno.b", "Dos");
    const now = new Date();
    expect(await recomputeStats(env.DB, now, { maxClubs: 1 })).toHaveLength(1);
    expect(await recomputeStats(env.DB, now)).toHaveLength(1);
    expect(await staleClubs(env.DB, now)).toEqual([]);

    await apply(a.owner.token, cmd(a.clubId, "member.createGuest", { id: crypto.randomUUID(), displayName: "Yoandry" }));
    expect(await staleClubs(env.DB, now)).toEqual([a.clubId]);
    await recomputeStats(env.DB, now);
    expect(await staleClubs(env.DB, now)).toEqual([]);

    const tomorrow = new Date(now.getTime() + 25 * 60 * 60 * 1000);
    expect((await staleClubs(env.DB, tomorrow)).sort()).toEqual([a.clubId, b.clubId].sort());
  });

  it("recalcular sin cambios no reescribe filas; lo que ya no está, se borra", async () => {
    const { clubId } = await activeClub();
    const staff = await ownerMemberId(clubId);
    const players = await seedMembers(clubId, 3);
    await seedWeekly(clubId, players, 2, staff);
    await recomputeClub(env.DB, clubId, new Date("2026-10-07T10:00:00.000Z"));
    const before = await memberStats(clubId);
    await recomputeClub(env.DB, clubId, new Date("2026-10-07T10:10:00.000Z"));
    expect((await memberStats(clubId)).map((r) => r.updated_at)).toEqual(before.map((r) => r.updated_at));

    // Se borran sus jornadas de uno: su fila desaparece.
    await env.DB.prepare("DELETE FROM reports WHERE member_id = ?").bind(players[0]).run();
    await env.DB.prepare("DELETE FROM attendance WHERE member_id = ?").bind(players[0]).run();
    await recomputeClub(env.DB, clubId, new Date());
    expect((await memberStats(clubId)).map((r) => r.member_id)).toEqual([players[1], players[2]]);
  });

  it("en la cola va primero el que hace más que no se intenta (uno que falla no frena a los demás)", async () => {
    const a = await activeClub("dueno.a", "Uno");
    const b = await activeClub("dueno.b", "Dos");
    const now = new Date();
    await env.DB.prepare("INSERT INTO stats_attempts (club_id, at) VALUES (?, ?), (?, ?)")
      .bind(a.clubId, new Date(now.getTime() - 60_000).toISOString(), b.clubId, new Date(now.getTime() - 3_600_000).toISOString())
      .run();
    expect(await staleClubs(env.DB, now)).toEqual([b.clubId, a.clubId]);
    // Recalcular deja constancia del intento.
    await recomputeStats(env.DB, now, { maxClubs: 1 });
    const at = await env.DB.prepare("SELECT at FROM stats_attempts WHERE club_id = ?").bind(b.clubId).first<{ at: string }>();
    expect(at!.at).toBe(now.toISOString());
  });

  it("la ruta de prestigio: solo miembros, y antes del primer cálculo dice Nuevo", async () => {
    const { clubId, owner } = await activeClub();
    const res = await api(`/clubs/${clubId}/prestige`, { token: owner.token });
    expect(res.body).toEqual({ tier: "new", score: 0, parts: [], newReason: null, computedAt: null });
    const outsider = await activeClub("otro");
    expect((await api(`/clubs/${clubId}/prestige`, { token: outsider.owner.token })).status).toBe(404);
  });
});

async function activeClubOwner(clubId: string) {
  // El token del dueño no se guardó en este test: se entra de nuevo.
  const row = await env.DB.prepare("SELECT u.username FROM clubs c JOIN users u ON u.id = c.owner_user_id WHERE c.id = ?")
    .bind(clubId)
    .first<{ username: string }>();
  const res = await api("/auth/login", { body: { username: row!.username, password: "secreto123" } });
  return res.body.token as string;
}
