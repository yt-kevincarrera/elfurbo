import { describe, expect, it } from "vitest";
import knockout from "../../shared-fixtures/knockout.json";
import standingsFixture from "../../shared-fixtures/standings.json";
import { loserOf, winnerOf, type KnockoutFixture } from "../src/rules/knockout";
import { standings, type StandingsFixture, type StandingsRules, type StandingsTeam } from "../src/rules/standings";

type StandingsCase = {
  name: string;
  rules: StandingsRules;
  teams: StandingsTeam[];
  fixtures: StandingsFixture[];
  events: { fixtureId: string; teamId: string; kind: string }[];
  expected: Record<string, unknown>[];
};

describe("shared-fixtures/standings.json (los mismos casos que la app)", () => {
  it.each(standingsFixture.cases as unknown as StandingsCase[])("$name", (c) => {
    const rows = standings(c.teams, c.fixtures, c.events, c.rules);
    expect(
      rows.map((r) => ({
        teamId: r.teamId,
        played: r.played,
        won: r.won,
        drawn: r.drawn,
        lost: r.lost,
        goalsFor: r.goalsFor,
        goalsAgainst: r.goalsAgainst,
        points: r.points,
      })),
    ).toEqual(c.expected);
  });
});

describe("shared-fixtures/knockout.json (los mismos casos que la app)", () => {
  type Case = { name: string; fixture: Partial<KnockoutFixture>; winner: string | null; loser: string | null };
  it.each(knockout.cases as unknown as Case[])("$name", (c) => {
    const f = { ...(knockout.base as KnockoutFixture), ...c.fixture };
    expect(winnerOf(f)).toBe(c.winner);
    expect(loserOf(f)).toBe(c.loser);
  });
});
