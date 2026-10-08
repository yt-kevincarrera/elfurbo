import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { recomputeClub } from "../src/stats/job";
import { activeClub, ownerMemberId } from "./fixtures";
import { api, register, type Registered } from "./helpers";
import { activeSeason, seedMembers, seedWeekly } from "./stats-helpers";
import { apply, cmd } from "./sync-helpers";

type Club = Awaited<ReturnType<typeof activeClub>>;

/** Mete a `user` en el servidor como jugador, directo en D1. */
async function join(clubId: string, user: Registered) {
  const id = crypto.randomUUID();
  const at = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, ?, 'player', ?, ?, ?)",
  )
    .bind(id, clubId, user.user.id, user.user.displayName, at, at)
    .run();
  return id;
}

/** Estadísticas ya calculadas para `memberId` en la temporada activa, con su nivel. */
async function stats(club: Club, memberId: string, played: number, goals: number, tier = "established") {
  const season = await activeSeason(club.clubId);
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO member_stats (club_id, period_id, member_id, played, goals, assists, mvps, updated_at) VALUES (?, ?, ?, ?, ?, 0, 0, ?)",
    ).bind(club.clubId, season, memberId, played, goals, new Date().toISOString()),
    env.DB.prepare("INSERT OR REPLACE INTO period_tiers (club_id, period_id, tier, score) VALUES (?, ?, ?, 50)").bind(
      club.clubId,
      season,
      tier,
    ),
  ]);
}

/**
 * Yoan juega en tres servidores: uno público, uno privado y uno privado que no comparte sus
 * estadísticas. Pepe es de fuera; Lía es compañera de Yoan en el privado.
 */
async function scenario() {
  const yoan = await register("yoan", "secreto123", "Yoan");
  const pepe = await register("pepe", "secreto123", "Pepe");
  const lia = await register("lia", "secreto123", "Lía");
  const pub = await activeClub("dueno.pub", "Los Pinos");
  const priv = await activeClub("dueno.priv", "La Peña");
  const closed = await activeClub("dueno.closed", "Secreto");
  await apply(pub.owner.token, cmd(pub.clubId, "club.setVisibility", { visibility: "public" }));
  await apply(closed.owner.token, cmd(closed.clubId, "club.updateSettings", { shareStats: false }));
  await stats(pub, await join(pub.clubId, yoan), 10, 8, "verified");
  await stats(priv, await join(priv.clubId, yoan), 5, 2, "established");
  await stats(closed, await join(closed.clubId, yoan), 3, 9, "casual");
  await join(priv.clubId, lia);
  return { yoan, pepe, lia, pub, priv, closed };
}

const profile = async (viewer: Registered, userId: string) => {
  const res = await api(`/players/${userId}`, { token: viewer.token });
  expect(res.status).toBe(200);
  return res.body;
};

describe("perfil global", () => {
  it("quien es de fuera: el público con nombre, el privado sin nombre y el que no comparte no sale", async () => {
    const { yoan, pepe, pub } = await scenario();
    const p = await profile(pepe, yoan.user.id);
    expect(p.user).toMatchObject({ id: yoan.user.id, username: "yoan", displayName: "Yoan", since: expect.any(String) });
    expect(p.memberships).toHaveLength(2);
    expect(p.memberships[0]).toMatchObject({
      clubId: pub.clubId,
      name: "Los Pinos",
      visibility: "public",
      periods: [{ tier: "verified", played: 10, goals: 8, frozen: false }],
    });
    expect(p.memberships[1]).toMatchObject({ clubId: null, name: null, visibility: "private", periods: [{ played: 5, goals: 2 }] });
    expect(p.totals).toEqual({
      all: { played: 15, goals: 10, assists: 0, mvps: 0 },
      trusted: { played: 10, goals: 8, assists: 0, mvps: 0 },
    });
    expect(p.settings).toBeUndefined();
  });

  it("una compañera del privado lo ve con nombre", async () => {
    const { yoan, lia, priv } = await scenario();
    const p = await profile(lia, yoan.user.id);
    expect(p.memberships.map((m: { name: string | null }) => m.name)).toEqual(["Los Pinos", "La Peña"]);
    expect(p.memberships[1].clubId).toBe(priv.clubId);
  });

  it("si Yoan oculta lo privado, los de fuera no lo ven, pero su compañera sí", async () => {
    const { yoan, pepe, lia } = await scenario();
    const res = await api("/me", { method: "PATCH", token: yoan.token, body: { showPrivateStats: false } });
    expect(res.body).toEqual({ settings: { showPrivateStats: false } });
    expect((await api("/me", { token: yoan.token })).body.settings).toEqual({ showPrivateStats: false });
    expect((await profile(pepe, yoan.user.id)).memberships).toHaveLength(1);
    expect((await profile(lia, yoan.user.id)).memberships).toHaveLength(2);
  });

  it("él mismo lo ve todo, también el servidor que no comparte, y sus ajustes", async () => {
    const { yoan } = await scenario();
    const p = await profile(yoan, yoan.user.id);
    expect(p.memberships.map((m: { name: string }) => m.name)).toEqual(["Los Pinos", "La Peña", "Secreto"]);
    expect(p.settings).toEqual({ showPrivateStats: true });
  });

  it("Índice Furbo: solo con 5 jornadas ponderadas o más", async () => {
    const { yoan, pepe } = await scenario();
    // verified 10 × 0.8 = 8 jornadas; established 5 × 0.5 = 2.5 → 10.5 ponderadas.
    // (8 × 0.8 + 2 × 0.5) / 10.5 = 0.70
    expect((await profile(pepe, yoan.user.id)).index).toBeCloseTo(0.7, 2);
    const nuevo = await register("nuevo");
    expect((await profile(pepe, nuevo.user.id)).index).toBeNull();
  });

  it("de punta a punta con el job: el nivel congelado de una temporada cerrada", async () => {
    const club = await activeClub();
    const staff = await ownerMemberId(club.clubId);
    const yoan = await register("yoan", "secreto123", "Yoan");
    const yoanMember = await join(club.clubId, yoan);
    const others = await seedMembers(club.clubId, 9);
    const season = await seedWeekly(club.clubId, [yoanMember, ...others], 12, staff, 2);
    await apply(club.owner.token, cmd(club.clubId, "season.setClosed", { seasonId: season, closed: true }));
    await recomputeClub(env.DB, club.clubId, new Date());
    const p = await profile(yoan, yoan.user.id);
    expect(p.memberships[0].periods[0]).toMatchObject({ periodId: season, played: 12, goals: 24, frozen: true });
    expect(p.memberships[0].periods[0].name).toEqual(expect.any(String));
  });

  it("buscar jugadores: por usuario o nombre, mínimo 2 letras, sin comodines", async () => {
    const me = await register("kevin", "secreto123", "Kevin");
    await register("yoan.p", "secreto123", "Yoan Pérez");
    await register("yoandry", "secreto123", "Yoandry");
    await register("raul", "secreto123", "Raúl el Yoyo");
    const search = async (q: string) =>
      (await api(`/players?q=${encodeURIComponent(q)}`, { token: me.token })).body.players.map((p: { username: string }) => p.username);
    expect(await search("yo")).toEqual(["raul", "yoan.p", "yoandry"]);
    expect(await search("YOAN")).toEqual(["yoan.p", "yoandry"]);
    expect(await search("y")).toEqual([]);
    expect(await search("%")).toEqual([]);
    expect((await api("/players?q=yo")).status).toBe(401);
  });

  it("un usuario que no existe: 404", async () => {
    const me = await register();
    expect((await api("/players/nadie", { token: me.token })).status).toBe(404);
  });

  it("PATCH /me valida", async () => {
    const me = await register();
    expect((await api("/me", { method: "PATCH", token: me.token, body: { showPrivateStats: "no" } })).status).toBe(400);
    expect((await api("/me", { method: "PATCH", token: me.token, body: { otra: true } })).status).toBe(400);
  });
});
