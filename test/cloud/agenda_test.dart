import 'package:elfurbo/cloud/sync/agenda.dart';
import 'package:elfurbo/cloud/sync/alerts.dart';
import 'package:elfurbo/cloud/sync/club_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

final now = DateTime.utc(2026, 10, 7, 15);

ClubData club(
  String id, {
  String name = 'Pachanga',
  int color = 0,
  String status = 'active',
}) => ClubData(clubId: id)
  ..table('club')[id] = {
    'id': id,
    'name': name,
    'status': status,
    'color': color,
    'settings': {'timezone': 'America/Havana', 'closeAfterHours': 72},
  }
  ..table('season')['s1'] = {'id': 's1', 'isClosed': false}
  ..table('season')['s0'] = {'id': 's0', 'isClosed': true};

void matchday(
  ClubData d,
  String id,
  DateTime at, {
  String status = 'scheduled',
  String season = 's1',
  String by = 'otro',
  int duration = 0,
}) => d.table('matchday')[id] = {
  'id': id,
  'seasonId': season,
  'startsAt': at.toIso8601String(),
  'durationMinutes': duration,
  'place': ' El Pre ',
  'status': status,
  'createdBy': by,
};

void intent(ClubData d, String md, String member, String? value) =>
    d.table('attendance')['$md:$member'] = {
      'id': '$md:$member',
      'matchdayId': md,
      'memberId': member,
      'intent': value,
    };

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es');
    tzdata.initializeTimeZones();
  });

  group('agendaItems', () {
    test(
      'junta las jornadas que vienen de todos los servidores, por fecha',
      () {
        final a = club('a', name: 'Los Pinos', color: 3);
        final b = club('b', name: 'El Pre');
        matchday(a, 'a1', now.add(const Duration(days: 3)));
        matchday(b, 'b1', now.add(const Duration(days: 1)));
        intent(b, 'b1', 'yo-b', 'yes');
        intent(b, 'b1', 'otro', 'yes');
        intent(b, 'b1', 'otro2', 'no');
        final items = agendaItems([
          (data: a, myMemberId: 'yo-a'),
          (data: b, myMemberId: 'yo-b'),
        ], now: now);
        expect(items.map((i) => i.matchdayId), ['b1', 'a1']);
        expect(items.first.myIntent, 'yes');
        expect(items.first.going, 2);
        expect(items.last.myIntent, isNull);
        expect(items.last.clubName, 'Los Pinos');
        expect(items.last.clubColor, 3);
        expect(items.last.place, 'El Pre');
      },
    );

    test(
      'fuera: las que ya empezaron, las canceladas, las de temporadas cerradas, '
      'las de más de 14 días y las de servidores suspendidos',
      () {
        final a = club('a');
        matchday(a, 'pasada', now.subtract(const Duration(hours: 1)));
        matchday(
          a,
          'cancelada',
          now.add(const Duration(days: 1)),
          status: 'cancelled',
        );
        matchday(a, 'cerrada', now.add(const Duration(days: 1)), season: 's0');
        matchday(
          a,
          'cerrada-a-mano',
          now.add(const Duration(days: 2)),
          status: 'closed',
        );
        matchday(a, 'lejos', now.add(const Duration(days: 15)));
        matchday(a, 'vale', now.add(const Duration(days: 14)));
        // Con duración: todavía se dice "voy" mientras dura.
        matchday(
          a,
          'en-juego',
          now.subtract(const Duration(minutes: 30)),
          duration: 120,
        );
        final suspendido = club('b', status: 'suspended');
        matchday(suspendido, 'b1', now.add(const Duration(days: 1)));
        final items = agendaItems([
          (data: a, myMemberId: 'yo'),
          (data: suspendido, myMemberId: 'yo'),
        ], now: now);
        expect(items.map((i) => i.matchdayId), ['en-juego', 'vale']);
      },
    );
  });

  group('pendingCount', () {
    test(
      'cuenta las jornadas de otros sin responder y los reportes por confirmar',
      () {
        final d = club('a')
          ..table('member')['yo'] = {'id': 'yo', 'displayName': 'Kevin'}
          ..table('member')['otro'] = {'id': 'otro', 'displayName': 'Yoan'};
        matchday(d, 'nueva', now.add(const Duration(days: 1)));
        matchday(d, 'respondida', now.add(const Duration(days: 2)));
        intent(d, 'respondida', 'yo', 'no');
        matchday(d, 'mia', now.add(const Duration(days: 2)), by: 'yo');
        // Una jugada ayer donde jugué y Yoan puso goles.
        matchday(d, 'ayer', now.subtract(const Duration(days: 1)));
        d.table('attendance')['ayer:yo'] = {
          'id': 'ayer:yo',
          'matchdayId': 'ayer',
          'memberId': 'yo',
          'played': true,
        };
        d.table('report')['ayer:otro'] = {
          'id': 'ayer:otro',
          'matchdayId': 'ayer',
          'memberId': 'otro',
          'goals': 1,
          'assists': 0,
          'decision': null,
          'updatedAt': 't',
        };
        expect(pendingCount(d, myMemberId: 'yo', now: now), 2);
      },
    );
  });
}
