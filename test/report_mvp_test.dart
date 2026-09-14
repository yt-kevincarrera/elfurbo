import 'package:elfurbo/domain/stats_engine.dart';
import 'package:elfurbo/models/match_report.dart';
import 'package:elfurbo/models/mvp_vote.dart';
import 'package:flutter_test/flutter_test.dart';

MvpVote vote(String voter, String votedFor) =>
    MvpVote(matchId: 'm', voterUid: voter, votedFor: votedFor);

MatchReport report(
  String uid,
  int goals,
  int assists, {
  bool confirmed = true,
}) => MatchReport(
  matchId: 'm',
  uid: uid,
  goals: goals,
  assists: assists,
  adminStatus: confirmed ? ReportStatus.confirmed : null,
);

void main() {
  group('mvpWinners', () {
    test('sin empate gana el más votado', () {
      final w = StatsEngine.mvpWinners([
        vote('x', 'a'),
        vote('y', 'a'),
        vote('z', 'b'),
      ]);
      expect(w, ['a']);
    });

    test('empate: gana quien tiene más goles confirmados', () {
      final w = StatsEngine.mvpWinners(
        [vote('x', 'a'), vote('y', 'b')],
        confirmedReports: {'a': report('a', 1, 0), 'b': report('b', 3, 0)},
      );
      expect(w, ['b']);
    });

    test('empate con mismos goles: gana más asistencias', () {
      final w = StatsEngine.mvpWinners(
        [vote('x', 'a'), vote('y', 'b')],
        confirmedReports: {'a': report('a', 2, 2), 'b': report('b', 2, 1)},
      );
      expect(w, ['a']);
    });

    test('todo igual: comparten, ordenados', () {
      final w = StatsEngine.mvpWinners(
        [vote('x', 'b'), vote('y', 'a')],
        confirmedReports: {'a': report('a', 1, 1), 'b': report('b', 1, 1)},
      );
      expect(w, ['a', 'b']);
    });

    test('sin reportes se comparte como antes', () {
      expect(StatsEngine.mvpWinners([vote('x', 'b'), vote('y', 'a')]), [
        'a',
        'b',
      ]);
    });

    test('quien no tiene reporte confirmado cuenta como 0 goles', () {
      final w = StatsEngine.mvpWinners(
        [vote('x', 'a'), vote('y', 'b')],
        confirmedReports: {'a': report('a', 1, 0)},
      );
      expect(w, ['a']);
    });
  });

  group('MatchReport', () {
    test('correctedBy marca corrección del admin', () {
      const r = MatchReport(
        matchId: 'm',
        uid: 'u',
        goals: 2,
        assists: 0,
        adminStatus: ReportStatus.confirmed,
        correctedBy: 'admin',
      );
      expect(r.correctedByAdmin, isTrue);
      expect(r.confirmedByAdmin, isTrue);
      expect(report('u', 1, 1).correctedByAdmin, isFalse);
    });

    test('rechazado no se puede editar por el autor', () {
      const r = MatchReport(
        matchId: 'm',
        uid: 'u',
        goals: 2,
        assists: 0,
        adminStatus: ReportStatus.rejected,
      );
      expect(r.isRejected, isTrue);
      expect(r.authorCanEdit, isFalse);
      expect(report('u', 1, 1, confirmed: false).authorCanEdit, isTrue);
    });
  });
}
