import 'package:elfurbo/domain/records.dart';
import 'package:elfurbo/domain/season_review.dart';
import 'package:elfurbo/domain/stats_engine.dart';
import 'package:elfurbo/models/attendance.dart';
import 'package:elfurbo/models/match_day.dart';
import 'package:elfurbo/models/match_report.dart';
import 'package:elfurbo/models/season.dart';
import 'package:flutter_test/flutter_test.dart';

MatchDay md(
  String id,
  int day, {
  String season = 's1',
  List<String> a = const [],
  List<String> b = const [],
}) => MatchDay(
  id: id,
  date: DateTime(2026, 3, day),
  seasonId: season,
  status: MatchStatus.scheduled,
  createdBy: 'admin',
  teamA: a,
  teamB: b,
);

MatchReport goals(String m, String uid, int g, [int a = 0]) => MatchReport(
  matchId: m,
  uid: uid,
  goals: g,
  assists: a,
  autoConfirmed: true,
);

Attendance played(String m, String uid) =>
    Attendance(matchId: m, uid: uid, played: true);

void main() {
  final now = DateTime(2026, 12);
  final matches = [
    md('m1', 1, a: ['ana', 'bea'], b: ['cris', 'dani']),
    md('m2', 8, a: ['ana', 'bea'], b: ['cris', 'dani']),
    md('m3', 15, a: ['ana', 'cris'], b: ['bea', 'dani']),
    md('m4', 22, season: 's2'),
  ];
  final attendance = [
    for (final m in ['m1', 'm2', 'm3'])
      for (final u in ['ana', 'bea', 'cris', 'dani']) played(m, u),
    played('m4', 'cris'),
  ];
  final reports = [
    goals('m1', 'ana', 3, 1),
    goals('m2', 'ana', 1),
    goals('m3', 'ana', 1),
    goals('m2', 'cris', 4),
    goals('m4', 'cris', 4),
  ];
  StatsEngine engine([String? season]) => StatsEngine(
    matches: matches,
    reports: reports,
    votes: const [],
    attendance: attendance,
    seasonId: season,
    now: now,
  );

  test('récords: el primero que lo logró, con quién y cuándo', () {
    final records = clubRecords(
      allTime: engine(),
      bySeason: [
        (
          Season(
            id: 's1',
            name: 'Apertura',
            startDate: DateTime(2026),
            isActive: false,
          ),
          engine('s1'),
        ),
        (
          Season(
            id: 's2',
            name: 'Clausura',
            startDate: DateTime(2026, 3, 20),
            isActive: true,
          ),
          engine('s2'),
        ),
      ],
      dateLabel: (d) => '${d.day}/${d.month}',
    );
    final byTitle = {for (final r in records) r.title: r};
    expect(byTitle['Más goles en una jornada']!.uid, 'cris');
    expect(byTitle['Más goles en una jornada']!.when, '8/3');
    expect(byTitle['Más goles en una temporada']!.uid, 'ana');
    expect(byTitle['Más goles en una temporada']!.value, 5);
    expect(byTitle['La racha goleadora más larga']!.uid, 'ana');
    expect(byTitle['La racha goleadora más larga']!.value, 3);
    expect(byTitle['Más jornadas seguidas']!.uid, 'cris');
    expect(byTitle['Más jornadas seguidas']!.value, 4);
    expect(byTitle.containsKey('Más MVP en una temporada'), false);
  });

  test('tu temporada: números, mejor día y con quién más jugó', () {
    final r = seasonReview(engine('s1'), 'ana');
    expect(r.played, 3);
    expect(r.goals, 5);
    expect(r.assists, 1);
    expect(r.position, 1);
    expect(r.bestDay!.date, DateTime(2026, 3, 1));
    expect(r.partner, (uid: 'bea', times: 2));
  });
}
