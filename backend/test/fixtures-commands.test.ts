import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub } from "./fixtures";
import { api, register, type Registered } from "./helpers";
import { apply, cmd, pullAll, rejection } from "./sync-helpers";

const post = (path: string, token: string, body: unknown = {}) => api(path, { method: "POST", token, body });

type Setup = {
  id: string;
  owner: Registered;
  teams: string[];
  /** Por equipo, sus jugadores (ids de miembro) y un usuario capitán. */
  rosters: Record<string, string[]>;
  captains: Record<string, Registered>;
};

/** Un torneo con 4 equipos aprobados de 3 jugadores cada uno, ya en juego. */
async function setup(start = true): Promise<Setup> {
  const host = await activeClub();
  const id = (await post(`/clubs/${host.clubId}/tournaments`, host.owner.token, { name: "Copa", format: "league" })).body.club.id;
  const teams: string[] = [];
  const rosters: Record<string, string[]> = {};
  const captains: Record<string, Registered> = {};
  const at = new Date().toISOString();
  for (const name of ["Águilas", "Búhos", "Cóndores", "Delfines"]) {
    const captain = await register(`cap.${name.length}${teams.length}`, "secreto123", name);
    const members = [crypto.randomUUID(), crypto.randomUUID(), crypto.randomUUID()];
    await env.DB.batch(
      members.map((m, i) =>
        env.DB.prepare(
          "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        ).bind(m, id, i === 0 ? captain.user.id : null, i === 0 ? "player" : "guest", `${name} ${i}`, at, at),
      ),
    );
    const teamId = crypto.randomUUID();
    await apply(host.owner.token, cmd(id, "team.create", { id: teamId, name, shortName: name.slice(0, 3), captainMemberId: members[0] }));
    for (const m of members.slice(1)) await apply(host.owner.token, cmd(id, "team.addPlayer", { teamId, memberId: m }));
    teams.push(teamId);
    rosters[teamId] = members;
    captains[teamId] = captain;
  }
  if (start) await apply(host.owner.token, cmd(id, "tournament.update", { status: "in_progress" }));
  return { id, owner: host.owner, teams, rosters, captains };
}

const fixture = (home: string | null, away: string | null, extra: Record<string, unknown> = {}) => ({
  id: crypto.randomUUID(),
  stage: "league",
  round: 1,
  homeTeamId: home,
  awayTeamId: away,
  ...extra,
});

async function row(id: string) {
  return env.DB.prepare("SELECT * FROM fixtures WHERE id = ?").bind(id).first<Record<string, unknown>>();
}

describe("calendario", () => {
  it("generar una liga: se crean los partidos y llegan por el pull; no se genera dos veces", async () => {
    const s = await setup(false);
    const [a, b, c, d] = s.teams as [string, string, string, string];
    const fixtures = [fixture(a, b), fixture(c, d), fixture(a, c, { round: 2 })];
    await apply(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "league", fixtures }));
    const pull = (await pullAll(s.owner.token)).clubs[s.id]!;
    expect(pull.upserts.fixture).toHaveLength(3);
    expect(await rejection(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "league", fixtures: [fixture(a, d)] }))).toBe(
      "invalid_state",
    );
    // Borrar y volver a generar.
    await apply(s.owner.token, cmd(s.id, "fixtures.clear", { stage: "league" }));
    expect(await row(fixtures[0]!.id)).toBeNull();
    await apply(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "league", fixtures: [fixture(a, d)] }));
  });

  it("rechaza equipos sin aprobar, fuentes a partidos que no existen y partidos de otra fase", async () => {
    const s = await setup(false);
    const [a, b] = s.teams as [string, string];
    for (const fixtures of [
      [fixture(a, "inventado")],
      [fixture(a, a)],
      [fixture(a, null, { stage: "knockout", awaySource: { winnerOf: crypto.randomUUID() } })],
      [fixture(a, b, { stage: "group" })],
    ]) {
      expect(await rejection(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "league", fixtures }))).toMatch(/invalid_input/);
    }
    const captain = s.captains[a]!;
    expect(await rejection(captain.token, cmd(s.id, "fixtures.generate", { stage: "league", fixtures: [fixture(a, b)] }))).toBe("forbidden");
  });

  it("grupos: se guarda el grupo de cada equipo", async () => {
    const s = await setup(false);
    const [a, b, c, d] = s.teams as [string, string, string, string];
    await apply(
      s.owner.token,
      cmd(s.id, "fixtures.generate", {
        stage: "group",
        fixtures: [fixture(a, b, { stage: "group", groupLabel: "A" }), fixture(c, d, { stage: "group", groupLabel: "B" })],
        groups: [
          { teamId: a, groupLabel: "A" },
          { teamId: b, groupLabel: "A" },
          { teamId: c, groupLabel: "B" },
          { teamId: d, groupLabel: "B" },
        ],
      }),
    );
    const t = await env.DB.prepare("SELECT group_label FROM teams WHERE id = ?").bind(c).first<{ group_label: string }>();
    expect(t!.group_label).toBe("B");
  });
});

describe("resultados", () => {
  it("con goles, asistencia, tarjeta, MVP y alineación; corregir reemplaza el detalle", async () => {
    const s = await setup();
    const [a, b] = s.teams as [string, string];
    const f = fixture(a, b);
    await apply(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "league", fixtures: [f] }));
    const [a0, a1] = s.rosters[a]! as [string, string];
    const [b0] = s.rosters[b]! as [string];
    const result = {
      fixtureId: f.id,
      homeScore: 2,
      awayScore: 1,
      events: [
        { id: crypto.randomUUID(), teamId: a, memberId: a0, kind: "goal", assistMemberId: a1 },
        { id: crypto.randomUUID(), teamId: b, memberId: b0, kind: "own_goal" },
        { id: crypto.randomUUID(), teamId: a, memberId: a1, kind: "goal" },
        { id: crypto.randomUUID(), teamId: b, memberId: b0, kind: "yellow" },
        { id: crypto.randomUUID(), teamId: a, memberId: a0, kind: "mvp" },
      ],
      lineups: { home: s.rosters[a], away: s.rosters[b] },
    };
    // 2 de A más un autogol de B (cuenta para A) = 3: no cuadra con 2-1.
    expect(await rejection(s.owner.token, cmd(s.id, "fixture.result", result))).toBe("invalid_input");
    result.events[1] = { id: crypto.randomUUID(), teamId: b, memberId: b0, kind: "goal" };
    await apply(s.owner.token, cmd(s.id, "fixture.result", result));
    expect(await row(f.id)).toMatchObject({ status: "played", home_score: 2, away_score: 1 });
    const count = async (table: string) =>
      (await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE fixture_id = ?`).bind(f.id).first<{ n: number }>())!.n;
    expect(await count("fixture_events")).toBe(5);
    expect(await count("fixture_lineups")).toBe(6);

    await apply(s.owner.token, cmd(s.id, "fixture.result", { fixtureId: f.id, homeScore: 0, awayScore: 0 }));
    expect(await count("fixture_events")).toBe(0);
    const pull = (await pullAll(s.owner.token)).clubs[s.id]!;
    expect(pull.upserts.fixtureEvent ?? []).toEqual([]);
  });

  it("lo pone el anotador del partido o el staff; un jugador cualquiera no", async () => {
    const s = await setup();
    const [a, b] = s.teams as [string, string];
    const f = fixture(a, b);
    await apply(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "league", fixtures: [f] }));
    const captain = s.captains[a]!;
    expect(await rejection(captain.token, cmd(s.id, "fixture.result", { fixtureId: f.id, homeScore: 1, awayScore: 0 }))).toBe("forbidden");
    await apply(s.owner.token, cmd(s.id, "fixture.schedule", { fixtureId: f.id, scorerMemberId: s.rosters[a]![0], place: "El Pre" }));
    await apply(captain.token, cmd(s.id, "fixture.result", { fixtureId: f.id, homeScore: 1, awayScore: 0 }));
    expect(await row(f.id)).toMatchObject({ place: "El Pre", home_score: 1 });
  });

  it("solo con el torneo en juego, y con jugadores de la plantilla", async () => {
    const s = await setup(false);
    const [a, b, c] = s.teams as [string, string, string];
    const f = fixture(a, b);
    await apply(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "league", fixtures: [f] }));
    expect(await rejection(s.owner.token, cmd(s.id, "fixture.result", { fixtureId: f.id, homeScore: 1, awayScore: 0 }))).toBe(
      "invalid_state",
    );
    await apply(s.owner.token, cmd(s.id, "tournament.update", { status: "in_progress" }));
    expect(
      await rejection(
        s.owner.token,
        cmd(s.id, "fixture.result", { fixtureId: f.id, homeScore: 0, awayScore: 0, lineups: { home: s.rosters[c], away: [] } }),
      ),
    ).toBe("invalid_input");
  });
});

describe("eliminatorias", () => {
  async function bracket() {
    const s = await setup();
    const [a, b, c, d] = s.teams as [string, string, string, string];
    const semi1 = fixture(a, d, { stage: "knockout", round: 1 });
    const semi2 = fixture(b, c, { stage: "knockout", round: 1 });
    const final = fixture(null, null, { stage: "knockout", round: 2, homeSource: { winnerOf: semi1.id }, awaySource: { winnerOf: semi2.id } });
    const third = fixture(null, null, { stage: "third", round: 2, homeSource: { loserOf: semi1.id }, awaySource: { loserOf: semi2.id } });
    await apply(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "knockout", fixtures: [semi1, semi2, final, third] }));
    return { s, a, b, c, d, semi1, semi2, final, third };
  }

  it("el ganador pasa a la final y el perdedor al tercer puesto; un empate necesita penales", async () => {
    const { s, a, c, d, semi1, semi2, final, third } = await bracket();
    expect(await rejection(s.owner.token, cmd(s.id, "fixture.result", { fixtureId: semi1.id, homeScore: 1, awayScore: 1 }))).toBe(
      "invalid_input",
    );
    await apply(s.owner.token, cmd(s.id, "fixture.result", { fixtureId: semi1.id, homeScore: 1, awayScore: 1, homePens: 4, awayPens: 3 }));
    expect(await row(final.id)).toMatchObject({ home_team_id: a });
    expect(await row(third.id)).toMatchObject({ home_team_id: d });
    await apply(s.owner.token, cmd(s.id, "fixture.setStatus", { fixtureId: semi2.id, status: "walkover", walkoverWinner: c }));
    expect(await row(final.id)).toMatchObject({ home_team_id: a, away_team_id: c });
    // Corregir la semi cambia quién va a la final, mientras la final no se haya jugado.
    await apply(s.owner.token, cmd(s.id, "fixture.result", { fixtureId: semi1.id, homeScore: 0, awayScore: 2 }));
    expect(await row(final.id)).toMatchObject({ home_team_id: d });
    await apply(s.owner.token, cmd(s.id, "fixture.result", { fixtureId: final.id, homeScore: 3, awayScore: 0 }));
    expect(await rejection(s.owner.token, cmd(s.id, "fixture.result", { fixtureId: semi1.id, homeScore: 5, awayScore: 0 }))).toBe(
      "invalid_state",
    );
    // El tercer puesto: los dos que perdieron las semis.
    expect(await row(third.id)).toMatchObject({ home_team_id: a, away_team_id: s.teams[1] });
  });

  it("volver a 'por jugar' borra el resultado y saca al que había pasado", async () => {
    const { s, semi1, final } = await bracket();
    await apply(s.owner.token, cmd(s.id, "fixture.result", { fixtureId: semi1.id, homeScore: 2, awayScore: 0 }));
    await apply(s.owner.token, cmd(s.id, "fixture.setStatus", { fixtureId: semi1.id, status: "scheduled" }));
    expect(await row(semi1.id)).toMatchObject({ status: "scheduled", home_score: null });
    expect(await row(final.id)).toMatchObject({ home_team_id: null });
  });

  it("de los grupos al cuadro: el organizador pone los equipos", async () => {
    const s = await setup();
    const [a, b] = s.teams as [string, string];
    const semi = fixture(null, null, { stage: "knockout", round: 4, homeSource: { group: "A", pos: 1 }, awaySource: { group: "B", pos: 2 } });
    await apply(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "knockout", fixtures: [semi] }));
    await apply(s.owner.token, cmd(s.id, "stage.advance", { assignments: [{ fixtureId: semi.id, homeTeamId: a, awayTeamId: b }] }));
    expect(await row(semi.id)).toMatchObject({ home_team_id: a, away_team_id: b });
    expect(await rejection(s.owner.token, cmd(s.id, "stage.advance", { assignments: [{ fixtureId: semi.id, homeTeamId: "otro" }] }))).toBe(
      "invalid_input",
    );
  });
});

describe("eliminatorias: sin rival", () => {
  it("un partido sin los dos equipos no admite resultado", async () => {
    const s = await setup();
    const [a] = s.teams as [string];
    const f = fixture(a, null, { stage: "knockout", round: 2, awaySource: { group: "A", pos: 1 } });
    await apply(s.owner.token, cmd(s.id, "fixtures.generate", { stage: "knockout", fixtures: [f] }));
    expect(await rejection(s.owner.token, cmd(s.id, "fixture.result", { fixtureId: f.id, homeScore: 1, awayScore: 0 }))).toBe(
      "invalid_state",
    );
  });
});
