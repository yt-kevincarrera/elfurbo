import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/rules/matchday_rules.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// Los mismos casos que ejecuta el backend (backend/test/shared-fixtures.test.ts).
void main() {
  tzdata.initializeTimeZones();
  final fixtures =
      jsonDecode(File('shared-fixtures/matchday-rules.json').readAsStringSync())
          as Map<String, dynamic>;
  final base = fixtures['matchday'] as Map<String, dynamic>;

  group('shared-fixtures/matchday-rules.json', () {
    for (final c in (fixtures['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        final m = {...base, ...?(c['matchday'] as Map<String, dynamic>?)};
        final md = MatchdayTimes(
          startsAt: DateTime.parse(m['startsAt'] as String),
          durationMinutes: m['durationMinutes'] as int,
          status: m['status'] as String,
          seasonClosed: m['seasonClosed'] as bool,
        );
        final at = DateTime.parse(c['at'] as String);
        final Object result = switch (c['fn']) {
          'isPlayed' => isPlayed(md, at),
          'acceptsIntent' => acceptsIntent(md, at),
          'isClosed' => isClosed(md, at, c['closeAfterHours'] as int),
          'localDay' => localDay(at, c['timezone'] as String),
          _ => throw StateError('fn desconocida: ${c['fn']}'),
        };
        expect(result, c['expected']);
      });
    }
  });
}
