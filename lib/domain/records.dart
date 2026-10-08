import '../models/season.dart';
import 'stats_engine.dart';

/// Un récord del servidor: quién lo tiene y cuándo (spec 2.0 §8.5).
class ClubRecord {
  const ClubRecord({
    required this.title,
    required this.value,
    required this.uid,
    this.when,
  });

  final String title;
  final int value;
  final String uid;

  /// La fecha de la jornada o el nombre de la temporada; null si es de
  /// siempre.
  final String? when;
}

/// Los récords del servidor. [allTime] es el histórico; [bySeason], el motor
/// de cada temporada. A igualdad gana el primero que lo logró (el orden de
/// las jornadas, o de las temporadas).
List<ClubRecord> clubRecords({
  required StatsEngine allTime,
  required List<(Season, StatsEngine)> bySeason,
  required String Function(DateTime) dateLabel,
}) {
  final out = <ClubRecord>[];

  // Más goles en una jornada.
  ({String uid, int goals, DateTime date})? bestDay;
  for (final m in allTime.playedMatches) {
    for (final r in allTime.reportsByMatch[m.id] ?? const []) {
      if (!r.isConfirmed || r.goals == 0) continue;
      if (bestDay == null || r.goals > bestDay.goals) {
        bestDay = (uid: r.uid, goals: r.goals, date: m.date);
      }
    }
  }
  if (bestDay != null) {
    out.add(
      ClubRecord(
        title: 'Más goles en una jornada',
        value: bestDay.goals,
        uid: bestDay.uid,
        when: dateLabel(bestDay.date),
      ),
    );
  }

  // Lo mejor de una temporada: goles y MVP.
  ClubRecord? bestOfSeason(String title, int Function(PlayerStats) value) {
    ClubRecord? best;
    for (final (season, engine) in bySeason) {
      final sorted = engine.stats.values.toList()
        ..sort((a, b) => a.uid.compareTo(b.uid));
      for (final s in sorted) {
        final v = value(s);
        if (v > 0 && (best == null || v > best.value)) {
          best = ClubRecord(
            title: title,
            value: v,
            uid: s.uid,
            when: season.name,
          );
        }
      }
    }
    return best;
  }

  out.addAll([
    ?bestOfSeason('Más goles en una temporada', (s) => s.goals),
    ?bestOfSeason('Más MVP en una temporada', (s) => s.mvps),
  ]);

  // Rachas del histórico: goles en jornadas seguidas, y jornadas seguidas.
  final scoring = <String, int>{};
  ({String uid, int n, DateTime date})? bestScoring;
  for (final m in allTime.playedMatches) {
    final scorers = {
      for (final r in allTime.reportsByMatch[m.id] ?? const [])
        if (r.isConfirmed && r.goals > 0) r.uid,
    };
    for (final uid in {...scoring.keys, ...scorers}) {
      final n = scorers.contains(uid) ? (scoring[uid] ?? 0) + 1 : 0;
      scoring[uid] = n;
      if (n > 1 && (bestScoring == null || n > bestScoring.n)) {
        bestScoring = (uid: uid, n: n, date: m.date);
      }
    }
  }
  if (bestScoring != null) {
    out.add(
      ClubRecord(
        title: 'La racha goleadora más larga',
        value: bestScoring.n,
        uid: bestScoring.uid,
        when: 'hasta el ${dateLabel(bestScoring.date)}',
      ),
    );
  }
  final streaks = allTime.stats.values.toList()
    ..sort((a, b) => a.uid.compareTo(b.uid));
  PlayerStats? attendance;
  for (final s in streaks) {
    if (s.bestStreak > 1 &&
        (attendance == null || s.bestStreak > attendance.bestStreak)) {
      attendance = s;
    }
  }
  if (attendance != null) {
    out.add(
      ClubRecord(
        title: 'Más jornadas seguidas',
        value: attendance.bestStreak,
        uid: attendance.uid,
      ),
    );
  }
  return out;
}
