/**
 * La tabla de una liga o de un grupo (spec 2.0 §7.5). Igual que
 * lib/domain/tournament/standings.dart: los dos pasan shared-fixtures/standings.json.
 */
export type StandingsTeam = { id: string; name: string; seed: number | null };
export type StandingsFixture = {
  id: string;
  homeTeamId: string | null;
  awayTeamId: string | null;
  status: string;
  homeScore: number | null;
  awayScore: number | null;
  walkoverWinner?: string | null;
};
export type StandingsEvent = { fixtureId: string; teamId: string; kind: string };
export type StandingsRules = { pointsWin: number; pointsDraw: number; pointsLoss: number; tiebreakers: string[] };

export type StandingRow = {
  teamId: string;
  played: number;
  won: number;
  drawn: number;
  lost: number;
  goalsFor: number;
  goalsAgainst: number;
  points: number;
  yellows: number;
  reds: number;
};

const row = (teamId: string): StandingRow => ({
  teamId,
  played: 0,
  won: 0,
  drawn: 0,
  lost: 0,
  goalsFor: 0,
  goalsAgainst: 0,
  points: 0,
  yellows: 0,
  reds: 0,
});

const decided = (f: StandingsFixture) => f.status === "played" || f.status === "walkover";

function apply(home: StandingRow, away: StandingRow, f: StandingsFixture, rules: StandingsRules) {
  home.played++;
  away.played++;
  const win = (w: StandingRow, l: StandingRow) => {
    w.won++;
    w.points += rules.pointsWin;
    l.lost++;
    l.points += rules.pointsLoss;
  };
  if (f.status === "walkover") {
    if (f.walkoverWinner === home.teamId) win(home, away);
    else win(away, home);
    return;
  }
  const hs = f.homeScore ?? 0;
  const as = f.awayScore ?? 0;
  home.goalsFor += hs;
  home.goalsAgainst += as;
  away.goalsFor += as;
  away.goalsAgainst += hs;
  if (hs === as) {
    home.drawn++;
    away.drawn++;
    home.points += rules.pointsDraw;
    away.points += rules.pointsDraw;
  } else if (hs > as) win(home, away);
  else win(away, home);
}

/** Parte un grupo de empatados por un criterio, de mejor a peor. */
function split(group: StandingRow[], criterion: string, fixtures: StandingsFixture[], rules: StandingsRules) {
  if (group.length < 2) return [group];
  let value: Map<string, number>;
  switch (criterion) {
    case "points":
      value = new Map(group.map((r) => [r.teamId, r.points]));
      break;
    case "goalDiff":
      value = new Map(group.map((r) => [r.teamId, r.goalsFor - r.goalsAgainst]));
      break;
    case "goalsFor":
      value = new Map(group.map((r) => [r.teamId, r.goalsFor]));
      break;
    case "fairPlay":
      value = new Map(group.map((r) => [r.teamId, -(r.yellows + 3 * r.reds)]));
      break;
    case "headToHead": {
      const mini = new Map(group.map((r) => [r.teamId, row(r.teamId)]));
      for (const f of fixtures) {
        const h = mini.get(f.homeTeamId ?? "");
        const a = mini.get(f.awayTeamId ?? "");
        if (h && a) apply(h, a, f, rules);
      }
      value = new Map([...mini.values()].map((r) => [r.teamId, r.points * 1000 + r.goalsFor - r.goalsAgainst]));
      break;
    }
    default:
      return [group];
  }
  const keys = [...new Set(value.values())].sort((a, b) => b - a);
  return keys.map((k) => group.filter((r) => value.get(r.teamId) === k));
}

export function standings(
  teams: StandingsTeam[],
  fixtures: StandingsFixture[],
  events: StandingsEvent[],
  rules: StandingsRules,
): StandingRow[] {
  const rows = new Map(teams.map((t) => [t.id, row(t.id)]));
  const counted = fixtures.filter((f) => decided(f) && rows.has(f.homeTeamId ?? "") && rows.has(f.awayTeamId ?? ""));
  const ids = new Set(counted.map((f) => f.id));
  for (const f of counted) apply(rows.get(f.homeTeamId!)!, rows.get(f.awayTeamId!)!, f, rules);
  for (const e of events) {
    const r = rows.get(e.teamId);
    if (!r || !ids.has(e.fixtureId)) continue;
    if (e.kind === "yellow") r.yellows++;
    if (e.kind === "red") r.reds++;
  }
  const byId = new Map(teams.map((t) => [t.id, t]));
  let groups = [[...rows.values()]];
  for (const criterion of rules.tiebreakers) groups = groups.flatMap((g) => split(g, criterion, counted, rules));
  const bySeed = (a: StandingRow, b: StandingRow) => {
    const sa = byId.get(a.teamId)?.seed ?? null;
    const sb = byId.get(b.teamId)?.seed ?? null;
    if (sa !== sb) {
      if (sa === null) return 1;
      if (sb === null) return -1;
      return sa - sb;
    }
    const na = (byId.get(a.teamId)?.name ?? "").toLowerCase();
    const nb = (byId.get(b.teamId)?.name ?? "").toLowerCase();
    return na < nb ? -1 : na > nb ? 1 : 0;
  };
  return groups.flatMap((g) => g.sort(bySeed));
}
