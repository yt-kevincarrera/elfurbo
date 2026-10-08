import 'stats_engine.dart';

/// "Tu temporada" (spec 2.0 §8.4): lo que hizo un jugador en una temporada.
class SeasonReview {
  const SeasonReview({
    required this.played,
    required this.goals,
    required this.assists,
    required this.mvps,
    required this.bestStreak,
    required this.position,
    this.bestDay,
    this.partner,
  });

  final int played;
  final int goals;
  final int assists;
  final int mvps;
  final int bestStreak;

  /// En la tabla de goles; null si no figura.
  final int? position;

  /// La jornada con más goles + asistencias.
  final ({DateTime date, int goals, int assists})? bestDay;

  /// Con quién más veces le tocó en el mismo equipo (si se guardaron equipos).
  final ({String uid, int times})? partner;
}

SeasonReview seasonReview(StatsEngine season, String uid) {
  final s = season.statsOf(uid);
  ({DateTime date, int goals, int assists})? bestDay;
  final together = <String, int>{};
  for (final m in season.playedMatches) {
    final r = (season.reportsByMatch[m.id] ?? const [])
        .where((r) => r.uid == uid && r.isConfirmed)
        .firstOrNull;
    if (r != null &&
        r.goals + r.assists > 0 &&
        (bestDay == null ||
            r.goals + r.assists > bestDay.goals + bestDay.assists)) {
      bestDay = (date: m.date, goals: r.goals, assists: r.assists);
    }
    final players = season.playersInMatch(m.id);
    if (!players.contains(uid)) continue;
    for (final team in [m.teamA, m.teamB]) {
      if (!team.contains(uid)) continue;
      for (final mate in team) {
        if (mate != uid && players.contains(mate)) {
          together[mate] = (together[mate] ?? 0) + 1;
        }
      }
    }
  }
  final mates = together.entries.toList()
    ..sort(
      (a, b) => b.value != a.value
          ? b.value.compareTo(a.value)
          : a.key.compareTo(b.key),
    );
  return SeasonReview(
    played: s.matchesPlayed,
    goals: s.goals,
    assists: s.assists,
    mvps: s.mvps,
    bestStreak: s.bestStreak,
    position: s.goals > 0 ? season.positionOf(uid, RankingKind.goals) : null,
    bestDay: bestDay,
    partner: mates.isEmpty
        ? null
        : (uid: mates.first.key, times: mates.first.value),
  );
}
