import '../models/attendance.dart';
import '../models/match_day.dart';
import '../models/match_report.dart';
import '../models/mvp_vote.dart';

/// Estadísticas acumuladas de un jugador en el período analizado.
class PlayerStats {
  PlayerStats(this.uid);

  final String uid;
  int matchesPlayed = 0;
  int goals = 0;
  int assists = 0;
  int mvps = 0;
  int pendingGoals = 0;
  int pendingAssists = 0;
  int hatTricks = 0;
  int pokers = 0;
  int completeMatches = 0; // gol + asistencia en el mismo partido
  int currentStreak = 0;
  int bestStreak = 0;
  int bestGoalsInMatch = 0;
  int mvpStreak = 0;
  int bestMvpStreak = 0;

  int get contributions => goals + assists;
  double get goalsPerMatch => matchesPlayed == 0 ? 0 : goals / matchesPlayed;
  double get assistsPerMatch =>
      matchesPlayed == 0 ? 0 : assists / matchesPlayed;

  /// Valoración usada para balancear equipos.
  double get rating {
    if (matchesPlayed == 0) return 0;
    return (goals + assists * 0.7 + mvps * 1.5) / matchesPlayed;
  }
}

/// Punto de la curva de evolución de un jugador.
class EvolutionPoint {
  const EvolutionPoint({
    required this.matchIndex,
    required this.date,
    required this.goals,
    required this.assists,
    required this.cumulativeGoals,
    required this.cumulativeAssists,
    required this.played,
    required this.mvp,
  });

  final int matchIndex;
  final DateTime date;
  final int goals;
  final int assists;
  final int cumulativeGoals;
  final int cumulativeAssists;
  final bool played;
  final bool mvp;
}

enum RankingKind { goals, assists, mvps, contributions }

/// Motor de estadísticas. Recibe TODOS los datos (ya cacheados localmente por
/// Firestore) y calcula tablas, perfiles y rachas para una temporada dada o
/// para el histórico total (`seasonId == null`).
///
/// Solo cuentan los reportes confirmados. Un jugador "jugó" una jornada si
/// tiene presencia real confirmada (`Attendance.isPresent`: la marcó él, el
/// admin al pasar lista, o cargó goles) o un reporte confirmado en ella. La
/// intención previa ("Voy") no cuenta.
class StatsEngine {
  StatsEngine({
    required List<MatchDay> matches,
    required List<MatchReport> reports,
    required List<MvpVote> votes,
    required List<Attendance> attendance,
    this.seasonId,
    DateTime? now,
  }) : now = now ?? DateTime.now() {
    _build(matches, reports, votes, attendance);
  }

  final String? seasonId;
  final DateTime now;

  late final List<MatchDay> playedMatches;
  late final Map<String, List<MatchReport>> reportsByMatch;
  late final Map<String, List<MvpVote>> votesByMatch;
  late final Map<String, Set<String>> attendeesByMatch;
  late final Map<String, List<String>> mvpsByMatch;
  late final Map<String, PlayerStats> stats;

  void _build(
    List<MatchDay> matches,
    List<MatchReport> reports,
    List<MvpVote> votes,
    List<Attendance> attendance,
  ) {
    playedMatches =
        matches
            .where((m) => m.isPlayed(now))
            .where((m) => seasonId == null || m.seasonId == seasonId)
            .toList()
          ..sort((a, b) => a.date.compareTo(b.date));
    final matchIds = playedMatches.map((m) => m.id).toSet();

    reportsByMatch = {};
    for (final r in reports) {
      if (!matchIds.contains(r.matchId)) continue;
      reportsByMatch.putIfAbsent(r.matchId, () => []).add(r);
    }
    votesByMatch = {};
    for (final v in votes) {
      if (!matchIds.contains(v.matchId)) continue;
      votesByMatch.putIfAbsent(v.matchId, () => []).add(v);
    }
    attendeesByMatch = {};
    for (final a in attendance) {
      if (!matchIds.contains(a.matchId)) continue;
      if (!a.isPresent) continue;
      attendeesByMatch.putIfAbsent(a.matchId, () => {}).add(a.uid);
    }

    mvpsByMatch = {
      for (final m in playedMatches)
        m.id: mvpWinners(votesByMatch[m.id] ?? const []),
    };

    stats = {};
    PlayerStats statsFor(String uid) =>
        stats.putIfAbsent(uid, () => PlayerStats(uid));

    // Rachas: recorremos los partidos en orden cronológico.
    final activeStreak = <String, int>{};
    final activeMvpStreak = <String, int>{};

    for (final m in playedMatches) {
      final played = playersInMatch(m.id);
      for (final uid in played) {
        final s = statsFor(uid);
        s.matchesPlayed++;
        final streak = (activeStreak[uid] ?? 0) + 1;
        activeStreak[uid] = streak;
        if (streak > s.bestStreak) s.bestStreak = streak;
      }
      for (final uid in activeStreak.keys.toList()) {
        if (!played.contains(uid)) activeStreak[uid] = 0;
      }

      for (final r in reportsByMatch[m.id] ?? const <MatchReport>[]) {
        final s = statsFor(r.uid);
        if (r.isConfirmed) {
          s.goals += r.goals;
          s.assists += r.assists;
          if (r.goals >= 3) s.hatTricks++;
          if (r.goals >= 4) s.pokers++;
          if (r.goals > 0 && r.assists > 0) s.completeMatches++;
          if (r.goals > s.bestGoalsInMatch) s.bestGoalsInMatch = r.goals;
        } else if (r.isPending) {
          s.pendingGoals += r.goals;
          s.pendingAssists += r.assists;
        }
      }

      final mvps = mvpsByMatch[m.id] ?? const [];
      for (final uid in mvps) {
        final s = statsFor(uid);
        s.mvps++;
        final streak = (activeMvpStreak[uid] ?? 0) + 1;
        activeMvpStreak[uid] = streak;
        if (streak > s.bestMvpStreak) s.bestMvpStreak = streak;
      }
      for (final uid in activeMvpStreak.keys.toList()) {
        if (!mvps.contains(uid)) activeMvpStreak[uid] = 0;
      }
    }

    for (final s in stats.values) {
      s.currentStreak = activeStreak[s.uid] ?? 0;
      s.mvpStreak = activeMvpStreak[s.uid] ?? 0;
    }
  }

  /// Jugadores que participaron de una jornada: presencia real o reporte confirmado.
  Set<String> playersInMatch(String matchId) {
    final set = <String>{...(attendeesByMatch[matchId] ?? const {})};
    for (final r in reportsByMatch[matchId] ?? const <MatchReport>[]) {
      if (r.isConfirmed) set.add(r.uid);
    }
    return set;
  }

  /// Ganador(es) de MVP de un partido. Si hay empate, todos los empatados.
  static List<String> mvpWinners(List<MvpVote> votes) {
    if (votes.isEmpty) return const [];
    final counts = <String, int>{};
    for (final v in votes) {
      counts[v.votedFor] = (counts[v.votedFor] ?? 0) + 1;
    }
    final max = counts.values.reduce((a, b) => a > b ? a : b);
    return counts.entries
        .where((e) => e.value == max)
        .map((e) => e.key)
        .toList()
      ..sort();
  }

  /// Conteo de votos por candidato en un partido, ordenado de mayor a menor.
  List<MapEntry<String, int>> voteCounts(String matchId) {
    final counts = <String, int>{};
    for (final v in votesByMatch[matchId] ?? const <MvpVote>[]) {
      counts[v.votedFor] = (counts[v.votedFor] ?? 0) + 1;
    }
    return counts.entries.toList()..sort(
      (a, b) => b.value != a.value
          ? b.value.compareTo(a.value)
          : a.key.compareTo(b.key),
    );
  }

  PlayerStats statsOf(String uid) => stats[uid] ?? PlayerStats(uid);

  /// Ranking por la métrica pedida. Solo aparecen jugadores con actividad.
  List<PlayerStats> ranking(RankingKind kind) {
    int value(PlayerStats s) => switch (kind) {
      RankingKind.goals => s.goals,
      RankingKind.assists => s.assists,
      RankingKind.mvps => s.mvps,
      RankingKind.contributions => s.contributions,
    };
    final list = stats.values.where((s) => s.matchesPlayed > 0).toList();
    list.sort((a, b) {
      final byValue = value(b).compareTo(value(a));
      if (byValue != 0) return byValue;
      final byContrib = b.contributions.compareTo(a.contributions);
      if (byContrib != 0) return byContrib;
      return a.matchesPlayed.compareTo(b.matchesPlayed);
    });
    return list;
  }

  /// Posición (1-based) de un jugador en un ranking, o null si no figura.
  int? positionOf(String uid, RankingKind kind) {
    final list = ranking(kind);
    final idx = list.indexWhere((s) => s.uid == uid);
    return idx < 0 ? null : idx + 1;
  }

  /// Curva partido a partido de un jugador (solo partidos del período).
  List<EvolutionPoint> evolution(String uid) {
    var cumGoals = 0;
    var cumAssists = 0;
    final points = <EvolutionPoint>[];
    for (var i = 0; i < playedMatches.length; i++) {
      final m = playedMatches[i];
      final report = (reportsByMatch[m.id] ?? const <MatchReport>[])
          .where((r) => r.uid == uid && r.isConfirmed)
          .firstOrNull;
      final goals = report?.goals ?? 0;
      final assists = report?.assists ?? 0;
      cumGoals += goals;
      cumAssists += assists;
      points.add(
        EvolutionPoint(
          matchIndex: i,
          date: m.date,
          goals: goals,
          assists: assists,
          cumulativeGoals: cumGoals,
          cumulativeAssists: cumAssists,
          played: playersInMatch(m.id).contains(uid),
          mvp: (mvpsByMatch[m.id] ?? const []).contains(uid),
        ),
      );
    }
    return points;
  }

  /// Resumen de un partido: goleadores confirmados, MVP y cantidad de jugadores.
  MatchSummary summary(String matchId) {
    final reports =
        (reportsByMatch[matchId] ?? const <MatchReport>[])
            .where((r) => r.isConfirmed)
            .toList()
          ..sort(
            (a, b) => b.goals != a.goals
                ? b.goals.compareTo(a.goals)
                : b.assists.compareTo(a.assists),
          );
    return MatchSummary(
      matchId: matchId,
      confirmedReports: reports,
      mvps: mvpsByMatch[matchId] ?? const [],
      players: playersInMatch(matchId),
      totalGoals: reports.fold(0, (sum, r) => sum + r.goals),
    );
  }
}

class MatchSummary {
  const MatchSummary({
    required this.matchId,
    required this.confirmedReports,
    required this.mvps,
    required this.players,
    required this.totalGoals,
  });

  final String matchId;
  final List<MatchReport> confirmedReports;
  final List<String> mvps;
  final Set<String> players;
  final int totalGoals;
}
