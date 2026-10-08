import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { recomputeClub } from "../src/stats/job";
import { tournamentTier } from "../src/stats/tournament-job";
import { activeClub } from "./fixtures";
import { api, register, type Registered } from "./helpers";
import { apply, cmd, rejection } from "./sync-helpers";

const post = (path: string, token: string, body: unknown = {}) => api(path, { method: "POST", token, body });

/**
 * Un torneo público en juego con 4 equipos; en cada uno, el capitán con cuenta y dos sin cuenta.
 * Un partido jugado: Águilas 2 - 1 Búhos, con goles, asistencia y MVP.
 */
async function played() {
  const host = await activeClub();
  const id = (await post(`/clubs/${host.clubId}/tournaments`, host.owner.token, { name: "Copa <Verano>", format: "league", visibility: "public" }))
    .body.club.id as string;
  const at = new Date().toISOString();
  const teams: string[] = [];
  const captains: Registered[] = [];
  const rosters: string[][] = [];
  for (const name of ["Águilas", "Búhos", "Cóndores", "Delfines"]) {
    const captain = await register(`cap${teams.length}`, "secreto123", `${name} capi`);
    const members = [crypto.randomUUID(), crypto.randomUUID()];
    await env.DB.batch(
      members.map((m, i) =>
        env.DB.prepare(
          "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        ).bind(m, id, i === 0 ? captain.user.id : null, i === 0 ? "player" : "guest", `${name} ${i}`, at, at),
      ),
    );
    const teamId = crypto.randomUUID();
    await apply(host.owner.token, cmd(id, "team.create", { id: teamId, name, shortName: name.slice(0, 3), captainMemberId: members[0] }));
    await apply(host.owner.token, cmd(id, "team.addPlayer", { teamId, memberId: members[1] }));
    teams.push(teamId);
    captains.push(captain);
    rosters.push(members);
  }
  await apply(host.owner.token, cmd(id, "tournament.update", { status: "in_progress" }));
  const f = { id: crypto.randomUUID(), stage: "league", round: 1, homeTeamId: teams[0], awayTeamId: teams[1] };
  await apply(host.owner.token, cmd(id, "fixtures.generate", { stage: "league", fixtures: [f] }));
  const [a0, a1] = rosters[0]!;
  const [b0, b1] = rosters[1]!;
  await apply(
    host.owner.token,
    cmd(id, "fixture.result", {
      fixtureId: f.id,
      homeScore: 2,
      awayScore: 1,
      events: [
        { id: crypto.randomUUID(), teamId: teams[0], memberId: a0, kind: "goal", assistMemberId: a1 },
        { id: crypto.randomUUID(), teamId: teams[0], memberId: a0, kind: "goal" },
        { id: crypto.randomUUID(), teamId: teams[1], memberId: b0, kind: "goal" },
        { id: crypto.randomUUID(), teamId: teams[1], memberId: b1, kind: "yellow" },
        { id: crypto.randomUUID(), teamId: teams[0], memberId: a0, kind: "mvp" },
      ],
      lineups: { home: rosters[0], away: rosters[1] },
    }),
  );
  return { host, id, teams, captains, rosters };
}

describe("terminar un torneo", () => {
  it("guarda los premios, lo deja terminado (sin cambios) y se puede reabrir", async () => {
    const { host, id, teams, rosters } = await played();
    const awards = [
      { kind: "champion", teamId: teams[0] },
      { kind: "runner_up", teamId: teams[1] },
      { kind: "top_scorer", memberId: rosters[0]![0], value: 2 },
      { kind: "best_player", memberId: rosters[0]![0] },
    ];
    expect(await rejection(host.owner.token, cmd(id, "tournament.finish", { awards: [...awards, { kind: "champion", teamId: teams[1] }] }))).toBe(
      "invalid_input",
    );
    expect(await rejection(host.owner.token, cmd(id, "tournament.finish", { awards: [{ kind: "champion", memberId: rosters[0]![0] }] }))).toBe(
      "invalid_input",
    );
    await apply(host.owner.token, cmd(id, "tournament.finish", { awards }));
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM awards WHERE club_id = ?").bind(id).first<{ n: number }>();
    expect(n!.n).toBe(4);
    expect(await rejection(host.owner.token, cmd(id, "tournament.update", { maxTeams: 8 }))).toBe("tournament_closed");
    await apply(host.owner.token, cmd(id, "tournament.reopen"));
    const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM awards WHERE club_id = ?").bind(id).first<{ n: number }>();
    expect(after!.n).toBe(0);
  });

  it("solo organizadores, y solo un torneo en juego", async () => {
    const { host, id, captains } = await played();
    expect(await rejection(captains[0]!.token, cmd(id, "tournament.finish", { awards: [] }))).toBe("forbidden");
    expect(await rejection(host.owner.token, cmd(id, "tournament.reopen"))).toBe("invalid_state");
  });
});

describe("estadísticas, nivel y vitrina de un torneo", () => {
  it("el nivel: oficial, verificado con anfitrión de prestigio, establecido o casual", () => {
    expect(tournamentTier(true, 2, null)).toBe("official");
    expect(tournamentTier(false, 3, "official")).toBe("casual");
    expect(tournamentTier(false, 4, "verified")).toBe("verified");
    expect(tournamentTier(false, 4, "established")).toBe("established");
    expect(tournamentTier(false, 8, null)).toBe("established");
  });

  it("el job cuenta alineaciones y eventos; el perfil global lo enseña con el trofeo", async () => {
    const { host, id, teams, captains, rosters } = await played();
    await apply(host.owner.token, cmd(id, "tournament.finish", { awards: [{ kind: "champion", teamId: teams[0] }, { kind: "top_scorer", memberId: rosters[0]![0], value: 2 }] }));
    await recomputeClub(env.DB, id, new Date());
    const stats = await env.DB.prepare("SELECT * FROM member_stats WHERE club_id = ? AND member_id = ?")
      .bind(id, rosters[0]![0])
      .first<Record<string, unknown>>();
    expect(stats).toMatchObject({ period_id: id, played: 1, goals: 2, mvps: 1 });
    const metrics = await env.DB.prepare("SELECT tier FROM club_metrics WHERE club_id = ?").bind(id).first<{ tier: string }>();
    expect(metrics!.tier).toBe("established");
    const frozen = await env.DB.prepare("SELECT frozen_at FROM period_tiers WHERE club_id = ? AND period_id = ?").bind(id, id).first();
    expect(frozen!.frozen_at).not.toBeNull();

    const someone = await register("cualquiera");
    const profile = (await api(`/players/${captains[0]!.user.id}`, { token: someone.token })).body;
    expect(profile.memberships[0]).toMatchObject({ kind: "tournament", name: "Copa <Verano>", periods: [{ name: "Copa <Verano>", goals: 2 }] });
    expect(profile.trophies).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "champion", tournament: "Copa <Verano>", teamName: "Águilas" }),
        expect.objectContaining({ kind: "top_scorer", value: 2 }),
      ]),
    );
    // El capitán de Búhos no ganó nada.
    expect((await api(`/players/${captains[1]!.user.id}`, { token: someone.token })).body.trophies).toEqual([]);
  });
});

describe("torneos en el directorio y su página", () => {
  it("la tarjeta dice en qué va y cuántos equipos tiene; el detalle, sus equipos", async () => {
    const { id } = await played();
    const kevin = await register("kevin");
    const list = await api("/directory?kind=tournament", { token: kevin.token });
    expect(list.body.clubs[0]).toMatchObject({ id, kind: "tournament", tournament: { status: "in_progress", teams: 4, registrationOpen: false } });
    const detail = await api(`/directory/${id}`, { token: kevin.token });
    expect(detail.body.club.teams).toHaveLength(4);
    expect(detail.body.club.champion).toBeNull();
  });

  it("/t/:id con la tabla, los resultados y los goleadores, todo escapado; privado da 404", async () => {
    const { id } = await played();
    const res = await exports.default.fetch(`https://api.test/t/${id}`);
    const html = await res.text();
    expect(res.status).toBe(200);
    expect(html).toContain("Copa &lt;Verano&gt;");
    expect(html).toContain("Águilas");
    expect(html).toContain("2 - 1");
    expect(html).toContain("Últimos resultados");
    const host = await activeClub("otro", "Otro");
    const priv = (await post(`/clubs/${host.clubId}/tournaments`, host.owner.token, { name: "Secreto", format: "cup" })).body.club.id;
    const hidden = await exports.default.fetch(`https://api.test/t/${priv}`);
    expect(hidden.status).toBe(404);
    expect(await hidden.text()).not.toContain("Secreto");
  });
});
