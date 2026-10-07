import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/domain/report_rules.dart';
import 'package:elfurbo/domain/stats_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Los mismos casos que ejecuta el backend (backend/test/stats-rules.test.ts):
/// la app y el servidor calculan igual las estadísticas.
void main() {
  final fixture =
      jsonDecode(File('shared-fixtures/stats.json').readAsStringSync())
          as Map<String, dynamic>;
  final data = (fixture['data'] as Map<String, dynamic>).map(
    (k, v) => MapEntry(k, (v as List).cast<Map<String, dynamic>>()),
  );
  final members = [for (final m in data['member']!) m['id'] as String];

  Map<String, int> numbers(PlayerStats s) => {
    'played': s.matchesPlayed,
    'goals': s.goals,
    'assists': s.assists,
    'mvps': s.mvps,
    'hatTricks': s.hatTricks,
    'pokers': s.pokers,
    'completeMatches': s.completeMatches,
    'bestDayGoals': s.bestGoalsInMatch,
    'bestStreak': s.bestStreak,
  };

  group('shared-fixtures/stats.json', () {
    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        final engine = statsFromCloud(
          data,
          settings: c['settings'] as Map<String, dynamic>,
          seasonId: c['seasonId'] as String?,
          now: DateTime.parse(c['now'] as String),
        );
        final expected = c['expected'] as Map<String, dynamic>;
        for (final id in members) {
          final got = numbers(engine.statsOf(id));
          if (expected.containsKey(id)) {
            expect(got, expected[id], reason: id);
          } else {
            expect(
              [got['played'], got['goals'], got['mvps']],
              [0, 0, 0],
              reason: id,
            );
          }
        }
      });
    }
  });
}
