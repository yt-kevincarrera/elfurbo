import '../../models/tournament.dart';

/// Una fila de la tabla.
class StandingRow {
  StandingRow(this.teamId);

  final String teamId;
  int played = 0;
  int won = 0;
  int drawn = 0;
  int lost = 0;
  int goalsFor = 0;
  int goalsAgainst = 0;
  int points = 0;
  int yellows = 0;
  int reds = 0;

  int get goalDiff => goalsFor - goalsAgainst;

  /// Fair play: menos es mejor (1 por amarilla, 3 por roja).
  int get cards => yellows + 3 * reds;
}

/// La tabla de una liga o de un grupo (spec 2.0 §7.5). Igual que
/// `backend/src/rules/standings.ts`: los dos pasan `shared-fixtures/standings.json`.
///
/// - Cuentan los partidos jugados y los ganados sin jugar (walkover: los
///   puntos de ganar, sin goles). Los cancelados y los por jugar, no.
/// - Desempates en el orden de [TournamentRules.tiebreakers]. `headToHead` mira
///   solo los partidos entre los empatados (puntos y luego diferencia).
/// - Si siguen empatados: el cabeza de serie (los sin serie al final) y el nombre.
List<StandingRow> standings({
  required List<Team> teams,
  required Iterable<Fixture> fixtures,
  required Iterable<FixtureEvent> events,
  required TournamentRules rules,
}) {
  final rows = {for (final t in teams) t.id: StandingRow(t.id)};
  final counted = [
    for (final f in fixtures)
      if (f.decided &&
          rows.containsKey(f.homeTeamId) &&
          rows.containsKey(f.awayTeamId))
        f,
  ];
  final ids = {for (final f in counted) f.id};
  for (final f in counted) {
    final home = rows[f.homeTeamId]!;
    final away = rows[f.awayTeamId]!;
    _apply(home, away, f, rules);
  }
  for (final e in events) {
    if (!ids.contains(e.fixtureId)) continue;
    final row = rows[e.teamId];
    if (row == null) continue;
    if (e.kind == EventKind.yellow) row.yellows++;
    if (e.kind == EventKind.red) row.reds++;
  }

  final byId = {for (final t in teams) t.id: t};
  var groups = [rows.values.toList()];
  // Siempre por puntos primero; la lista dice cómo se desempata.
  for (final criterion in [
    'points',
    ...rules.tiebreakers.where((c) => c != 'points'),
  ]) {
    groups = [for (final g in groups) ..._split(g, criterion, counted, rules)];
  }
  int bySeed(StandingRow a, StandingRow b) {
    final sa = byId[a.teamId]?.seed;
    final sb = byId[b.teamId]?.seed;
    if (sa != sb) {
      if (sa == null) return 1;
      if (sb == null) return -1;
      return sa.compareTo(sb);
    }
    return (byId[a.teamId]?.name ?? '').toLowerCase().compareTo(
      (byId[b.teamId]?.name ?? '').toLowerCase(),
    );
  }

  return [for (final g in groups) ...(g..sort(bySeed))];
}

void _apply(
  StandingRow home,
  StandingRow away,
  Fixture f,
  TournamentRules rules,
) {
  home.played++;
  away.played++;
  if (f.status == FixtureStatus.walkover) {
    final (winner, loser) = f.walkoverWinner == home.teamId
        ? (home, away)
        : (away, home);
    winner
      ..won += 1
      ..points += rules.pointsWin;
    loser
      ..lost += 1
      ..points += rules.pointsLoss;
    return;
  }
  final hs = f.homeScore ?? 0;
  final aw = f.awayScore ?? 0;
  home
    ..goalsFor += hs
    ..goalsAgainst += aw;
  away
    ..goalsFor += aw
    ..goalsAgainst += hs;
  if (hs == aw) {
    home
      ..drawn += 1
      ..points += rules.pointsDraw;
    away
      ..drawn += 1
      ..points += rules.pointsDraw;
  } else {
    final (winner, loser) = hs > aw ? (home, away) : (away, home);
    winner
      ..won += 1
      ..points += rules.pointsWin;
    loser
      ..lost += 1
      ..points += rules.pointsLoss;
  }
}

/// Parte un grupo de empatados por un criterio, de mejor a peor.
List<List<StandingRow>> _split(
  List<StandingRow> group,
  String criterion,
  List<Fixture> fixtures,
  TournamentRules rules,
) {
  if (group.length < 2) return [group];
  final Map<String, int> value;
  switch (criterion) {
    case 'points':
      value = {for (final r in group) r.teamId: r.points};
    case 'goalDiff':
      value = {for (final r in group) r.teamId: r.goalDiff};
    case 'goalsFor':
      value = {for (final r in group) r.teamId: r.goalsFor};
    case 'fairPlay':
      // Menos tarjetas es mejor: se invierte para ordenar de mayor a menor.
      value = {for (final r in group) r.teamId: -r.cards};
    case 'headToHead':
      final mini = {for (final r in group) r.teamId: StandingRow(r.teamId)};
      for (final f in fixtures) {
        final h = mini[f.homeTeamId];
        final a = mini[f.awayTeamId];
        if (h != null && a != null) _apply(h, a, f, rules);
      }
      value = {
        for (final r in mini.values) r.teamId: r.points * 1000 + r.goalDiff,
      };
    default:
      return [group];
  }
  final keys = value.values.toSet().toList()..sort((a, b) => b.compareTo(a));
  final out = [
    for (final k in keys)
      [
        for (final r in group)
          if (value[r.teamId] == k) r,
      ],
  ];
  // Con el enfrentamiento directo, los que siguen empatados entre menos se
  // vuelven a mirar solo entre ellos.
  if (criterion != 'headToHead' || out.length == 1) return out;
  return [
    for (final g in out)
      if (g.length > 1 && g.length < group.length)
        ..._split(g, criterion, fixtures, rules)
      else
        g,
  ];
}
