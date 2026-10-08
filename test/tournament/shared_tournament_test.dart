import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/domain/tournament/knockout.dart';
import 'package:elfurbo/domain/tournament/standings.dart';
import 'package:elfurbo/models/tournament.dart';
import 'package:flutter_test/flutter_test.dart';

/// Los mismos casos que el backend (backend/test/tournament-rules.test.ts).
void main() {
  Map<String, dynamic> load(String name) =>
      jsonDecode(File('shared-fixtures/$name').readAsStringSync())
          as Map<String, dynamic>;

  group('shared-fixtures/standings.json', () {
    for (final c
        in (load('standings.json')['cases'] as List)
            .cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        final rows = standings(
          teams: [
            for (final t in (c['teams'] as List).cast<Map<String, dynamic>>())
              Team(
                id: t['id'] as String,
                name: t['name'] as String,
                shortName: t['id'] as String,
                status: TeamStatus.approved,
                seed: (t['seed'] as num?)?.toInt(),
              ),
          ],
          fixtures: [
            for (final f
                in (c['fixtures'] as List).cast<Map<String, dynamic>>())
              Fixture.fromCloud({...f, 'stage': 'league', 'round': 1}),
          ],
          events: [
            for (final (i, e)
                in (c['events'] as List).cast<Map<String, dynamic>>().indexed)
              FixtureEvent.fromCloud({...e, 'id': 'e$i', 'memberId': 'x'}),
          ],
          rules: TournamentRules.fromCloud(c['rules'] as Map<String, dynamic>),
        );
        expect([
          for (final r in rows)
            {
              'teamId': r.teamId,
              'played': r.played,
              'won': r.won,
              'drawn': r.drawn,
              'lost': r.lost,
              'goalsFor': r.goalsFor,
              'goalsAgainst': r.goalsAgainst,
              'points': r.points,
            },
        ], c['expected']);
      });
    }
  });

  group('shared-fixtures/knockout.json', () {
    final fixture = load('knockout.json');
    final base = fixture['base'] as Map<String, dynamic>;
    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        final f = Fixture.fromCloud({
          ...base,
          ...(c['fixture'] as Map<String, dynamic>),
          'stage': 'knockout',
          'round': 1,
        });
        expect(winnerOf(f), c['winner']);
        expect(loserOf(f), c['loser']);
      });
    }
  });
}
