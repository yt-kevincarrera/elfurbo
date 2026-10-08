/**
 * Quién pasa de un partido de eliminatoria (spec 2.0 §7.3). Igual que
 * lib/domain/tournament/knockout.dart: los dos pasan shared-fixtures/knockout.json.
 */
export type KnockoutFixture = {
  homeTeamId: string | null;
  awayTeamId: string | null;
  status: string;
  homeScore: number | null;
  awayScore: number | null;
  homePens: number | null;
  awayPens: number | null;
  walkoverWinner: string | null;
};

/** El de más goles; si empatan, el de más penales; ganado sin jugar, el que se dio. null si no se sabe. */
export function winnerOf(f: KnockoutFixture): string | null {
  if (!f.homeTeamId || !f.awayTeamId) return null;
  if (f.status === "walkover") return f.walkoverWinner;
  if (f.status !== "played" || f.homeScore === null || f.awayScore === null) return null;
  if (f.homeScore !== f.awayScore) return f.homeScore > f.awayScore ? f.homeTeamId : f.awayTeamId;
  if (f.homePens === null || f.awayPens === null || f.homePens === f.awayPens) return null;
  return f.homePens > f.awayPens ? f.homeTeamId : f.awayTeamId;
}

/** El que queda fuera (para el tercer puesto). */
export function loserOf(f: KnockoutFixture): string | null {
  const w = winnerOf(f);
  if (w === null) return null;
  return w === f.homeTeamId ? f.awayTeamId : f.homeTeamId;
}
