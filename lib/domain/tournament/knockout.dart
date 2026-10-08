import '../../models/tournament.dart';

/// Quién pasa de un partido de eliminatoria (spec 2.0 §7.3): el de más goles;
/// si empatan, el de más penales; ganado sin jugar, el que se dio. null si
/// todavía no se sabe. Igual que `backend/src/rules/knockout.ts`
/// (`shared-fixtures/knockout.json`).
String? winnerOf(Fixture f) {
  if (!f.hasTeams) return null;
  if (f.status == FixtureStatus.walkover) return f.walkoverWinner;
  if (f.status != FixtureStatus.played) return null;
  final hs = f.homeScore;
  final aw = f.awayScore;
  if (hs == null || aw == null) return null;
  if (hs != aw) return hs > aw ? f.homeTeamId : f.awayTeamId;
  final hp = f.homePens;
  final ap = f.awayPens;
  if (hp == null || ap == null || hp == ap) return null;
  return hp > ap ? f.homeTeamId : f.awayTeamId;
}

/// El que queda fuera (para el partido por el tercer puesto).
String? loserOf(Fixture f) {
  final w = winnerOf(f);
  if (w == null) return null;
  return w == f.homeTeamId ? f.awayTeamId : f.homeTeamId;
}

/// Lo que cambia en los partidos que dependen de [decided]: `(partido, lado,
/// equipo)`. Lado es `home` o `away`; equipo null si deja de saberse.
List<(String fixtureId, String side, String? teamId)> dependents(
  Fixture decided,
  Iterable<Fixture> fixtures,
) {
  final winner = winnerOf(decided);
  final loser = loserOf(decided);
  String? teamFor(TeamSource? s) {
    if (s == null) return null;
    if (s.winnerOf == decided.id) return winner;
    if (s.loserOf == decided.id) return loser;
    return null;
  }

  bool fed(TeamSource? s) =>
      s != null && (s.winnerOf == decided.id || s.loserOf == decided.id);
  return [
    for (final f in fixtures) ...[
      if (fed(f.homeSource)) (f.id, 'home', teamFor(f.homeSource)),
      if (fed(f.awaySource)) (f.id, 'away', teamFor(f.awaySource)),
    ],
  ];
}
