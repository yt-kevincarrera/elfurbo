import 'package:elfurbo/domain/stats_engine.dart';
import 'package:elfurbo/models/attendance.dart';
import 'package:elfurbo/models/match_day.dart';
import 'package:elfurbo/models/match_report.dart';
import 'package:elfurbo/models/mvp_vote.dart';
import 'package:flutter_test/flutter_test.dart';

MatchDay match(
  String id,
  DateTime date, {
  String season = 's1',
  MatchStatus status = MatchStatus.scheduled,
}) => MatchDay(
  id: id,
  date: date,
  seasonId: season,
  status: status,
  createdBy: 'admin',
);

Attendance yes(String matchId, String uid) =>
    Attendance(matchId: matchId, uid: uid, status: AttendanceStatus.yes);

void main() {
  final now = DateTime(2026, 9, 13);
  final m1 = match('m1', DateTime(2026, 8, 30));
  final m2 = match('m2', DateTime(2026, 9, 6));
  final m3 = match('m3', DateTime(2026, 9, 20)); // futuro
  final cancelled = match(
    'mc',
    DateTime(2026, 8, 23),
    status: MatchStatus.cancelled,
  );

  test('solo cuentan reportes confirmados; los pendientes van aparte', () {
    final engine = StatsEngine(
      now: now,
      matches: [m1, m2, m3, cancelled],
      attendance: [yes('m1', 'a'), yes('m1', 'b'), yes('m1', 'c')],
      reports: [
        // confirmado por 2 compañeros
        const MatchReport(
          matchId: 'm1',
          uid: 'a',
          goals: 2,
          assists: 1,
          confirmations: ['b', 'c'],
        ),
        // pendiente (1 confirmación)
        const MatchReport(
          matchId: 'm1',
          uid: 'b',
          goals: 5,
          assists: 0,
          confirmations: ['a'],
        ),
        // confirmado por admin
        const MatchReport(
          matchId: 'm1',
          uid: 'c',
          goals: 1,
          assists: 2,
          adminStatus: ReportStatus.confirmed,
        ),
        // rechazado por admin aunque tenga 2 confirmaciones
        const MatchReport(
          matchId: 'm2',
          uid: 'a',
          goals: 9,
          assists: 9,
          confirmations: ['b', 'c'],
          adminStatus: ReportStatus.rejected,
        ),
        // en partido futuro: no cuenta
        const MatchReport(
          matchId: 'm3',
          uid: 'a',
          goals: 3,
          assists: 0,
          adminStatus: ReportStatus.confirmed,
        ),
        // en partido cancelado: no cuenta
        const MatchReport(
          matchId: 'mc',
          uid: 'a',
          goals: 3,
          assists: 0,
          adminStatus: ReportStatus.confirmed,
        ),
      ],
      votes: const [],
    );

    expect(engine.playedMatches.map((m) => m.id), ['m1', 'm2']);
    expect(engine.statsOf('a').goals, 2);
    expect(engine.statsOf('a').assists, 1);
    expect(engine.statsOf('b').goals, 0);
    expect(engine.statsOf('b').pendingGoals, 5);
    expect(engine.statsOf('c').goals, 1);
    expect(engine.statsOf('c').assists, 2);
    expect(engine.ranking(RankingKind.goals).map((s) => s.uid), [
      'a',
      'c',
      'b',
    ]);
    expect(engine.ranking(RankingKind.assists).first.uid, 'c');
  });

  test('MVP con empate premia a todos; rachas de asistencia', () {
    final m4 = match('m4', DateTime(2026, 9, 12));
    final engine = StatsEngine(
      now: now,
      matches: [m1, m2, m4],
      attendance: [
        yes('m1', 'a'),
        yes('m1', 'b'),
        yes('m2', 'a'),
        yes('m4', 'a'),
        yes('m4', 'b'),
      ],
      reports: const [],
      votes: const [
        MvpVote(matchId: 'm1', voterUid: 'a', votedFor: 'b'),
        MvpVote(matchId: 'm1', voterUid: 'b', votedFor: 'a'),
        MvpVote(matchId: 'm2', voterUid: 'b', votedFor: 'a'),
        MvpVote(matchId: 'm4', voterUid: 'a', votedFor: 'b'),
        MvpVote(matchId: 'm4', voterUid: 'c', votedFor: 'b'),
      ],
    );

    expect(engine.mvpsByMatch['m1'], ['a', 'b']);
    expect(engine.mvpsByMatch['m2'], ['a']);
    expect(engine.mvpsByMatch['m4'], ['b']);
    expect(engine.statsOf('a').mvps, 2);
    expect(engine.statsOf('b').mvps, 2);
    expect(engine.statsOf('a').bestMvpStreak, 2);
    expect(engine.statsOf('a').currentStreak, 3);
    expect(engine.statsOf('b').currentStreak, 1);
    expect(engine.statsOf('b').bestStreak, 1);
    expect(engine.statsOf('a').matchesPlayed, 3);
    expect(engine.statsOf('b').matchesPlayed, 2);
  });

  test('filtro por temporada y evolución acumulada', () {
    final old = match('old', DateTime(2025, 12, 1), season: 's0');
    final engine = StatsEngine(
      now: now,
      seasonId: 's1',
      matches: [old, m1, m2],
      attendance: [yes('old', 'a'), yes('m1', 'a'), yes('m2', 'a')],
      reports: const [
        MatchReport(
          matchId: 'old',
          uid: 'a',
          goals: 7,
          assists: 0,
          adminStatus: ReportStatus.confirmed,
        ),
        MatchReport(
          matchId: 'm1',
          uid: 'a',
          goals: 1,
          assists: 1,
          adminStatus: ReportStatus.confirmed,
        ),
        MatchReport(
          matchId: 'm2',
          uid: 'a',
          goals: 3,
          assists: 0,
          adminStatus: ReportStatus.confirmed,
        ),
      ],
      votes: const [],
    );
    expect(engine.statsOf('a').goals, 4);
    expect(engine.statsOf('a').hatTricks, 1);
    expect(engine.statsOf('a').completeMatches, 1);
    final evo = engine.evolution('a');
    expect(evo.map((p) => p.cumulativeGoals), [1, 4]);
    expect(evo.map((p) => p.cumulativeAssists), [1, 1]);

    final allTime = StatsEngine(
      now: now,
      matches: [old, m1, m2],
      attendance: [yes('old', 'a')],
      reports: const [
        MatchReport(
          matchId: 'old',
          uid: 'a',
          goals: 7,
          assists: 0,
          adminStatus: ReportStatus.confirmed,
        ),
      ],
      votes: const [],
    );
    expect(allTime.statsOf('a').goals, 7);
  });

  test(
    'un jugador con reporte confirmado cuenta como que jugó aunque no marcó asistencia',
    () {
      final engine = StatsEngine(
        now: now,
        matches: [m1],
        attendance: const [],
        reports: const [
          MatchReport(
            matchId: 'm1',
            uid: 'z',
            goals: 1,
            assists: 0,
            adminStatus: ReportStatus.confirmed,
          ),
        ],
        votes: const [],
      );
      expect(engine.statsOf('z').matchesPlayed, 1);
      expect(engine.summary('m1').players, {'z'});
      expect(engine.summary('m1').totalGoals, 1);
    },
  );
}
