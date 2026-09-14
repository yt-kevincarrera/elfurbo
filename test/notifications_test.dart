import 'package:elfurbo/domain/reminders.dart';
import 'package:elfurbo/models/attendance.dart';
import 'package:elfurbo/models/match_day.dart';
import 'package:elfurbo/models/notification_payload.dart';
import 'package:flutter_test/flutter_test.dart';

MatchDay m(
  String id,
  DateTime date, {
  MatchStatus status = MatchStatus.scheduled,
  String? place,
}) => MatchDay(
  id: id,
  date: date,
  seasonId: 's',
  status: status,
  createdBy: 'a',
  place: place,
);

void main() {
  group('NotificationPayload', () {
    test('encode/decode ida y vuelta', () {
      const p = NotificationPayload(
        kind: NotificationKind.report,
        matchId: 'm1',
      );
      final back = NotificationPayload.decode(p.encode());
      expect(back.kind, NotificationKind.report);
      expect(back.matchId, 'm1');
    });

    test('decode tolera null y basura', () {
      expect(NotificationPayload.decode(null).kind, NotificationKind.unknown);
      expect(
        NotificationPayload.decode('no es json').kind,
        NotificationKind.unknown,
      );
    });

    test('fromFcmData usa los tipos de las Functions', () {
      expect(
        NotificationPayload.fromFcmData({
          'type': 'match_day',
          'matchId': 'm2',
        }).kind,
        NotificationKind.matchDay,
      );
      expect(
        NotificationPayload.fromFcmData({'type': 'pending_user'}).kind,
        NotificationKind.pendingUser,
      );
      expect(
        NotificationPayload.fromFcmData({'type': 'report_status'}).kind,
        NotificationKind.reportStatus,
      );
      expect(
        NotificationPayload.fromFcmData({'type': 'post_match'}).kind,
        NotificationKind.postMatch,
      );
      expect(
        NotificationPayload.fromFcmData({}).kind,
        NotificationKind.unknown,
      );
    });

    test('update lleva el tag', () {
      const p = NotificationPayload(
        kind: NotificationKind.update,
        tag: 'v0.2.0',
      );
      expect(NotificationPayload.decode(p.encode()).tag, 'v0.2.0');
    });
  });

  group('plannedReminders', () {
    final now = DateTime(2026, 9, 14, 12); // lunes mediodía
    final sunday = DateTime(2026, 9, 20, 10); // domingo 10:00

    test('dos recordatorios por jornada futura: 09:00 y 22:00', () {
      final list = plannedReminders(
        [m('m1', sunday, place: 'La Loma')],
        const {},
        now,
      );
      expect(list.length, 2);
      expect(list[0].at, DateTime(2026, 9, 20, 9));
      expect(list[0].title, '¡Hoy se juega!');
      expect(list[0].body, contains('10:00'));
      expect(list[0].body, contains('La Loma'));
      expect(list[1].at, DateTime(2026, 9, 20, 22));
      expect(list[1].matchId, 'm1');
      expect(list[0].id, isNot(list[1].id));
    });

    test('omite canceladas, "no voy" y fuera de horizonte', () {
      final list = plannedReminders(
        [
          m('c', sunday, status: MatchStatus.cancelled),
          m('n', sunday.add(const Duration(days: 1))),
          m('far', now.add(const Duration(days: 40))),
        ],
        {'n': AttendanceStatus.no},
        now,
      );
      expect(list, isEmpty);
    });

    test('omite horarios que ya pasaron pero conserva los futuros', () {
      // Jornada hoy a las 10:00; ahora son las 12:00: solo queda el de 22:00.
      final list = plannedReminders(
        [m('t', DateTime(2026, 9, 14, 10))],
        const {},
        now,
      );
      expect(list.length, 1);
      expect(list.single.at, DateTime(2026, 9, 14, 22));
    });

    test(
      'jornada que termina después de las 22:00 no recuerda cargar goles',
      () {
        final list = plannedReminders(
          [m('late', DateTime(2026, 9, 20, 21))],
          const {},
          now,
        );
        expect(list.map((r) => r.at), [DateTime(2026, 9, 20, 9)]);
      },
    );

    test('ids únicos y dentro del rango reservado', () {
      final matches = [
        for (var i = 0; i < 60; i++)
          m('m$i', now.add(Duration(days: 1 + (i % 12), hours: i % 5))),
      ];
      final list = plannedReminders(matches, const {}, now);
      final ids = list.map((r) => r.id).toSet();
      expect(ids.length, list.length);
      expect(ids.every((id) => id >= 5000 && id < 5100), isTrue);
    });
  });
}
