import 'package:elfurbo/domain/tournament/generators.dart';
import 'package:elfurbo/domain/tournament/player_stats.dart';
import 'package:elfurbo/models/tournament.dart';
import 'package:flutter_test/flutter_test.dart';

String Function() ids() {
  var n = 0;
  return () => 'f${n++}';
}

void main() {
  group('liga', () {
    for (final n in [2, 3, 4, 5, 8]) {
      test(
        '$n equipos: cada pareja una vez por vuelta y nadie dos veces en una ronda',
        () {
          final teams = [for (var i = 0; i < n; i++) 't$i'];
          for (final legs in [1, 2]) {
            final f = leagueFixtures(teams, newId: ids(), legs: legs);
            expect(f.length, legs * n * (n - 1) ~/ 2);
            final pairs = <String, int>{};
            for (final x in f) {
              final key = ([x.homeTeamId!, x.awayTeamId!]..sort()).join('-');
              pairs[key] = (pairs[key] ?? 0) + 1;
            }
            expect(pairs.length, n * (n - 1) ~/ 2);
            expect(pairs.values.toSet(), {legs});
            final byRound = <int, List<String>>{};
            for (final x in f) {
              byRound.putIfAbsent(x.round, () => [])
                ..add(x.homeTeamId!)
                ..add(x.awayTeamId!);
            }
            for (final r in byRound.values) {
              expect(r.toSet().length, r.length, reason: 'repite en una ronda');
            }
            final rounds = n.isEven ? n - 1 : n;
            expect(byRound.length, legs * rounds);
          }
        },
      );
    }

    test('a dos vueltas, la vuelta cambia local y visitante', () {
      final f = leagueFixtures(['a', 'b'], newId: ids(), legs: 2);
      expect([f[0].homeTeamId, f[0].awayTeamId], ['a', 'b']);
      expect([f[1].homeTeamId, f[1].awayTeamId], ['b', 'a']);
      expect(f[1].leg, 2);
    });
  });

  group('copa', () {
    test('el orden de siembra', () {
      expect(seedOrder(4), [1, 4, 2, 3]);
      expect(seedOrder(8), [1, 8, 4, 5, 2, 7, 3, 6]);
    });

    test('8 equipos: cuartos, semis y final, con el tercer puesto', () {
      final teams = [for (var i = 1; i <= 8; i++) Entrant.team('s$i')];
      final f = cupFixtures(teams, newId: ids(), thirdPlace: true);
      expect(f.where((x) => x.stage == FixtureStage.knockout).length, 7);
      final first = f.where((x) => x.round == 1).toList();
      expect([first[0].homeTeamId, first[0].awayTeamId], ['s1', 's8']);
      final third = f.singleWhere((x) => x.stage == FixtureStage.third);
      expect(third.homeSource!.loserOf, isNotNull);
      final finalMatch = f.singleWhere(
        (x) => x.stage == FixtureStage.knockout && x.round == 3,
      );
      expect(finalMatch.homeSource!.winnerOf, isNotNull);
      expect(finalMatch.awaySource!.winnerOf, isNotNull);
    });

    test('5 equipos: los 3 mejores pasan la primera ronda sin jugar', () {
      final teams = [for (var i = 1; i <= 5; i++) Entrant.team('s$i')];
      final f = cupFixtures(teams, newId: ids());
      final first = f.where((x) => x.round == 1).toList();
      expect(first, hasLength(1));
      expect({first.single.homeTeamId, first.single.awayTeamId}, {'s4', 's5'});
      final second = f.where((x) => x.round == 2).toList();
      expect(second, hasLength(2));
      // El 1 espera al ganador del 4-5.
      expect(second[0].homeTeamId, 's1');
      expect(second[0].awaySource!.winnerOf, first.single.id);
      expect([second[1].homeTeamId, second[1].awayTeamId], ['s2', 's3']);
      expect(f.where((x) => x.round == 3), hasLength(1));
    });
  });

  group('grupos y copa', () {
    test('serpiente: los cabezas de serie quedan separados', () {
      final g = drawGroups(['1', '2', '3', '4', '5', '6', '7', '8'], 2);
      expect(g['A'], ['1', '4', '5', '8']);
      expect(g['B'], ['2', '3', '6', '7']);
    });

    test('2 grupos de 4, pasan 2: 1.º A contra 2.º B en semis', () {
      final r = groupsCupFixtures([
        for (var i = 1; i <= 8; i++) 't$i',
      ], newId: ids());
      final group = r.fixtures.where((f) => f.stage == FixtureStage.group);
      expect(group, hasLength(12));
      final ko = r.fixtures
          .where((f) => f.stage == FixtureStage.knockout)
          .toList();
      expect(ko, hasLength(3));
      final semi = ko.first;
      expect(semi.round, 4);
      expect(semi.homeSource!.group, 'A');
      expect(semi.homeSource!.pos, 1);
      expect(semi.awaySource!.group, 'B');
      expect(semi.awaySource!.pos, 2);
    });
  });

  test(
    '3 grupos, pasan 2: nadie se cruza con uno de su grupo en la primera ronda',
    () {
      final r = groupsCupFixtures(
        [for (var i = 1; i <= 9; i++) 't$i'],
        newId: ids(),
        groups: 3,
      );
      final ko = r.fixtures.where((f) => f.stage == FixtureStage.knockout);
      final first = ko.where(
        (f) =>
            f.round == ko.map((x) => x.round).reduce((a, b) => a < b ? a : b),
      );
      for (final f in first) {
        final hg = f.homeSource?.group;
        final ag = f.awaySource?.group;
        if (hg != null && ag != null) expect(hg, isNot(ag));
      }
    },
  );

  test('las fechas no se corren con el cambio de hora', () {
    final f = leagueFixtures(['a', 'b', 'c', 'd'], newId: ids());
    // En Cuba se atrasa la hora el primer domingo de noviembre.
    scheduleWeekly(f, DateTime(2026, 10, 24));
    expect(f.last.startsAt, DateTime(2026, 11, 7, 15));
  });

  test('una ronda por semana desde el día de inicio', () {
    final f = leagueFixtures(['a', 'b', 'c', 'd'], newId: ids());
    scheduleWeekly(f, DateTime(2026, 11, 7));
    expect(f.first.startsAt, DateTime(2026, 11, 7, 15));
    expect(f.last.startsAt, DateTime(2026, 11, 21, 15));
  });

  group('jugadores', () {
    Fixture fixture(String id, int round, {bool played = true}) =>
        Fixture.fromCloud({
          'id': id,
          'stage': 'league',
          'round': round,
          'homeTeamId': 'A',
          'awayTeamId': 'B',
          'status': played ? 'played' : 'scheduled',
          'homeScore': 1,
          'awayScore': 0,
        });
    FixtureEvent event(
      String fixture,
      String member,
      String kind, {
      String? assist,
    }) => FixtureEvent.fromCloud({
      'id': '$fixture-$member-$kind',
      'fixtureId': fixture,
      'teamId': 'A',
      'memberId': member,
      'kind': kind,
      'assistMemberId': assist,
    });

    test('goles, asistencias y MVP; el autogol no suma', () {
      final stats = tournamentPlayerStats(
        fixtures: [fixture('f1', 1), fixture('f2', 2, played: false)],
        events: [
          event('f1', 'p1', 'goal', assist: 'p2'),
          event('f1', 'p3', 'own_goal'),
          event('f1', 'p1', 'mvp'),
          event('f2', 'p1', 'goal'),
        ],
        lineups: [
          const FixtureLineup(fixtureId: 'f1', teamId: 'A', memberId: 'p1'),
        ],
      );
      expect(stats['p1']!.goals, 1);
      expect(stats['p1']!.mvps, 1);
      expect(stats['p1']!.played, 1);
      expect(stats['p2']!.assists, 1);
      expect(stats.containsKey('p3'), isFalse);
      expect(leaders(stats, (s) => s.goals).map((s) => s.memberId), ['p1']);
    });

    test(
      '3 amarillas suspenden el partido siguiente; una roja, los que diga la regla',
      () {
        final fixtures = [
          for (var r = 1; r <= 5; r++) fixture('f$r', r, played: r <= 3),
        ];
        final out = suspensions(
          fixtures: fixtures,
          events: [
            event('f1', 'p1', 'yellow'),
            event('f2', 'p1', 'yellow'),
            event('f3', 'p1', 'yellow'),
            event('f1', 'p2', 'red'),
          ],
          rules: const TournamentRules(yellowsForBan: 3, redBanMatches: 2),
        );
        expect(out['f2'], {'p2'});
        expect(out['f3'], {'p2'});
        expect(out['f4'], {'p1'});
        expect(out['f5'], isEmpty);
      },
    );
  });
}
