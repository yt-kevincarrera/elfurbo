import '../../models/tournament.dart';

/// Lo de un jugador en el torneo, de los eventos y las alineaciones.
class TournamentPlayerStats {
  TournamentPlayerStats(this.memberId);

  final String memberId;
  int played = 0;
  int goals = 0;
  int assists = 0;
  int mvps = 0;
  int yellows = 0;
  int reds = 0;
}

/// Goles, asistencias, MVP, tarjetas y partidos jugados por miembro. Solo
/// cuentan los partidos con resultado; un autogol no suma para nadie.
Map<String, TournamentPlayerStats> tournamentPlayerStats({
  required Iterable<Fixture> fixtures,
  required Iterable<FixtureEvent> events,
  required Iterable<FixtureLineup> lineups,
}) {
  final decided = {
    for (final f in fixtures)
      if (f.status == FixtureStatus.played) f.id,
  };
  final out = <String, TournamentPlayerStats>{};
  TournamentPlayerStats of(String id) =>
      out.putIfAbsent(id, () => TournamentPlayerStats(id));
  for (final l in lineups) {
    if (decided.contains(l.fixtureId)) of(l.memberId).played++;
  }
  for (final e in events) {
    if (!decided.contains(e.fixtureId)) continue;
    switch (e.kind) {
      case EventKind.goal:
        of(e.memberId).goals++;
        if (e.assistMemberId != null) of(e.assistMemberId!).assists++;
      case EventKind.ownGoal:
        break;
      case EventKind.yellow:
        of(e.memberId).yellows++;
      case EventKind.red:
        of(e.memberId).reds++;
      case EventKind.mvp:
        of(e.memberId).mvps++;
    }
  }
  return out;
}

/// Los mejores por [value] (sin los que tienen 0), de mayor a menor.
List<TournamentPlayerStats> leaders(
  Map<String, TournamentPlayerStats> stats,
  int Function(TournamentPlayerStats) value,
) => stats.values.where((s) => value(s) > 0).toList()
  ..sort(
    (a, b) => value(b) != value(a)
        ? value(b).compareTo(value(a))
        : a.played.compareTo(b.played),
  );

/// Suspensiones automáticas (spec 2.0 §7.5): [TournamentRules.yellowsForBan]
/// amarillas acumuladas suspenden el partido siguiente de su equipo (y el
/// contador vuelve a empezar); una roja, [TournamentRules.redBanMatches]
/// partidos. Devuelve, por partido, quién no puede jugarlo (también los que
/// están por jugar).
Map<String, Set<String>> suspensions({
  required List<Fixture> fixtures,
  required Iterable<FixtureEvent> events,
  required TournamentRules rules,
}) {
  final ordered =
      [...fixtures.where((f) => f.status != FixtureStatus.cancelled)]
        ..sort((a, b) {
          if (a.round != b.round) return a.round.compareTo(b.round);
          final da = a.startsAt;
          final db = b.startsAt;
          if (da != null && db != null && da != db) return da.compareTo(db);
          return a.id.compareTo(b.id);
        });
  final byFixture = <String, List<FixtureEvent>>{};
  for (final e in events) {
    byFixture.putIfAbsent(e.fixtureId, () => []).add(e);
  }
  // Por equipo: partidos de suspensión pendientes de cada jugador, y amarillas.
  final bans = <String, Map<String, int>>{};
  final yellows = <String, int>{};
  final out = <String, Set<String>>{};
  // Un partido aplazado de una ronda anterior no "cumple" la suspensión si el
  // equipo ya jugó después: cuenta desde su último partido jugado.
  final lastPlayed = <String, int>{};
  for (final (i, f) in ordered.indexed) {
    if (f.status != FixtureStatus.played) continue;
    for (final team in [f.homeTeamId, f.awayTeamId]) {
      if (team != null) lastPlayed[team] = i;
    }
  }
  for (final (i, f) in ordered.indexed) {
    for (final team in [f.homeTeamId, f.awayTeamId]) {
      if (team == null) continue;
      if (f.status != FixtureStatus.played && i < (lastPlayed[team] ?? -1)) {
        continue;
      }
      final pending = bans[team] ?? {};
      final out0 = out.putIfAbsent(f.id, () => {});
      for (final e in pending.entries.toList()) {
        if (e.value <= 0) continue;
        out0.add(e.key);
        pending[e.key] = e.value - 1;
      }
    }
    if (f.status != FixtureStatus.played) continue;
    for (final e in byFixture[f.id] ?? const <FixtureEvent>[]) {
      final pending = bans.putIfAbsent(e.teamId, () => {});
      if (e.kind == EventKind.red && rules.redBanMatches > 0) {
        pending[e.memberId] = (pending[e.memberId] ?? 0) + rules.redBanMatches;
      }
      if (e.kind == EventKind.yellow && rules.yellowsForBan > 0) {
        final n = (yellows[e.memberId] ?? 0) + 1;
        if (n >= rules.yellowsForBan) {
          pending[e.memberId] = (pending[e.memberId] ?? 0) + 1;
          yellows[e.memberId] = 0;
        } else {
          yellows[e.memberId] = n;
        }
      }
    }
  }
  return out;
}
