import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/domain/checkin.dart';
import 'package:elfurbo/domain/waitlist.dart';
import 'package:elfurbo/models/attendance.dart';
import 'package:flutter_test/flutter_test.dart';

/// Los mismos casos que ejecuta el backend (backend/test/checkin.test.ts).
void main() {
  final fixtures =
      jsonDecode(File('shared-fixtures/checkin.json').readAsStringSync())
          as Map<String, dynamic>;

  group('shared-fixtures/checkin.json', () {
    for (final c in (fixtures['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        expect(
          checkinCode(c['secret'] as String, DateTime.parse(c['at'] as String)),
          c['code'],
        );
      });
    }
  });

  test('lo que le queda al código y cuándo vale "Estoy aquí"', () {
    expect(
      checkinRemaining(DateTime.utc(2026, 10, 10, 20, 3)),
      const Duration(minutes: 2),
    );
    final start = DateTime.utc(2026, 10, 10, 20);
    final end = start.add(const Duration(hours: 2));
    expect(
      checkinOpen(start, end, start.subtract(const Duration(hours: 3))),
      true,
    );
    expect(
      checkinOpen(start, end, start.subtract(const Duration(hours: 4))),
      false,
    );
    expect(checkinOpen(start, end, end.add(const Duration(hours: 3))), true);
    expect(checkinOpen(start, end, end.add(const Duration(hours: 4))), false);
  });

  test(
    'cupo: dentro los primeros por la hora del "Voy", el resto en espera',
    () {
      Attendance a(
        String uid,
        int? minute, [
        AttendanceStatus s = AttendanceStatus.yes,
      ]) => Attendance(
        matchId: 'm',
        uid: uid,
        status: s,
        intentAt: minute == null ? null : DateTime.utc(2026, 1, 1, 0, minute),
      );
      final list = [
        a('d', 4),
        a('b', 2),
        a('x', 1, AttendanceStatus.maybe),
        a('c', 2),
        a('old', null),
      ];
      final w = waitlist(list, 3);
      expect(w.inside, ['old', 'b', 'c']);
      expect(w.waiting, ['d']);
      expect(waitlist(list, 0).waiting, isEmpty);
      expect(waitlist(list, 0).inside, hasLength(4));
    },
  );
}
