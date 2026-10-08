import 'package:elfurbo/domain/tournament/awards.dart';
import 'package:elfurbo/models/tournament.dart';
import 'package:flutter_test/flutter_test.dart';

Team team(String id) =>
    Team(id: id, name: id, shortName: id, status: TeamStatus.approved);

Fixture fixture(
  String id,
  String stage,
  int round,
  String home,
  String away,
  int hs,
  int as_,
) => Fixture.fromCloud({
  'id': id,
  'stage': stage,
  'round': round,
  'homeTeamId': home,
  'awayTeamId': away,
  'status': 'played',
  'homeScore': hs,
  'awayScore': as_,
});

FixtureEvent event(String f, String team, String member, String kind) =>
    FixtureEvent.fromCloud({
      'id': '$f-$member-$kind-${team.hashCode}',
      'fixtureId': f,
      'teamId': team,
      'memberId': member,
      'kind': kind,
    });

void main() {
  test(
    'copa: campeón y subcampeón de la final, tercero, goleador, MVP y fair play',
    () {
      final p = proposeAwards(
        tournament: Tournament.fromCloud({
          'id': 't',
          'format': 'cup',
          'status': 'in_progress',
        }),
        teams: [team('A'), team('B'), team('C'), team('D')],
        fixtures: [
          fixture('s1', 'knockout', 1, 'A', 'D', 2, 0),
          fixture('s2', 'knockout', 1, 'B', 'C', 1, 0),
          fixture('fin', 'knockout', 2, 'A', 'B', 0, 3),
          fixture('3p', 'third', 2, 'D', 'C', 1, 2),
        ],
        events: [
          event('s1', 'A', 'a1', 'goal'),
          event('s1', 'A', 'a1', 'goal'),
          event('fin', 'B', 'b1', 'goal'),
          event('fin', 'B', 'b1', 'mvp'),
          event('s1', 'A', 'a2', 'yellow'),
          event('s2', 'C', 'c1', 'red'),
        ],
        lineups: const [],
      );
      String? teamOf(String kind) => p.firstWhere((a) => a.kind == kind).teamId;
      expect(teamOf('champion'), 'B');
      expect(teamOf('runner_up'), 'A');
      expect(teamOf('third'), 'C');
      expect(p.firstWhere((a) => a.kind == 'top_scorer').memberId, 'a1');
      expect(p.firstWhere((a) => a.kind == 'top_scorer').value, 2);
      expect(p.firstWhere((a) => a.kind == 'best_player').memberId, 'b1');
      expect(teamOf('fair_play'), anyOf('B', 'D'));
    },
  );

  test('fair play: uno que se retiró no se lo lleva', () {
    final p = proposeAwards(
      tournament: Tournament.fromCloud({
        'id': 't',
        'format': 'league',
        'status': 'in_progress',
      }),
      teams: [
        team('A'),
        team('B'),
        Team(id: 'X', name: 'X', shortName: 'X', status: TeamStatus.withdrawn),
      ],
      fixtures: [
        fixture('f1', 'league', 1, 'A', 'B', 1, 0),
        fixture('f2', 'league', 1, 'X', 'A', 0, 1),
      ],
      events: [event('f1', 'A', 'a1', 'yellow'), event('f1', 'B', 'b1', 'red')],
      lineups: const [],
    );
    expect(p.firstWhere((a) => a.kind == 'fair_play').teamId, 'A');
  });

  test(
    'liga: campeón y subcampeón de la tabla; sin partidos no se propone nada',
    () {
      final t = Tournament.fromCloud({
        'id': 't',
        'format': 'league',
        'status': 'in_progress',
      });
      final p = proposeAwards(
        tournament: t,
        teams: [team('A'), team('B')],
        fixtures: [fixture('f1', 'league', 1, 'A', 'B', 0, 1)],
        events: const [],
        lineups: const [],
      );
      expect(p.firstWhere((a) => a.kind == 'champion').teamId, 'B');
      expect(p.firstWhere((a) => a.kind == 'runner_up').teamId, 'A');
      expect(
        proposeAwards(
          tournament: t,
          teams: [team('A')],
          fixtures: const [],
          events: const [],
          lineups: const [],
        ),
        isEmpty,
      );
    },
  );
}
