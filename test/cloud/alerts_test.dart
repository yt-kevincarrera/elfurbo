import 'dart:io';

import 'package:elfurbo/cloud/sync/alerts.dart';
import 'package:elfurbo/cloud/sync/club_data.dart';
import 'package:elfurbo/cloud/sync/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

final now = DateTime.utc(2026, 10, 7, 15);
const me = 'm-yo';

/// Un servidor con dos miembros más (Yoan y Pepe) y lo que cada test añada.
ClubData club({Map<String, Object?> settings = const {}}) {
  final d = ClubData(clubId: 'c1', cursor: 1);
  d.table('club')['c1'] = {
    'id': 'c1',
    'name': 'Pachanga',
    'status': 'active',
    'settings': {
      'timezone': 'America/Havana',
      'closeAfterHours': 72,
      'confirmationsNeeded': 2,
      'reportValidation': 'confirm',
      ...settings,
    },
  };
  for (final (id, name) in [
    (me, 'Kevin'),
    ('m-yoan', 'Yoan'),
    ('m-pepe', 'Pepe'),
  ]) {
    d.table('member')[id] = {'id': id, 'displayName': name, 'status': 'active'};
  }
  d.table('season')['s1'] = {'id': 's1', 'isClosed': false};
  return d;
}

void matchday(
  ClubData d,
  String id,
  DateTime startsAt, {
  String by = 'm-yoan',
  String status = 'scheduled',
}) => d.table('matchday')[id] = {
  'id': id,
  'seasonId': 's1',
  'startsAt': startsAt.toIso8601String(),
  'durationMinutes': 0,
  'place': 'El Pre',
  'status': status,
  'createdBy': by,
};

void played(ClubData d, String md, String member) =>
    d.table('attendance')['$md:$member'] = {
      'id': '$md:$member',
      'matchdayId': md,
      'memberId': member,
      'played': true,
    };

void report(
  ClubData d,
  String md,
  String member, {
  String? decision,
  String updatedAt = 't1',
  int goals = 2,
}) => d.table('report')['$md:$member'] = {
  'id': '$md:$member',
  'matchdayId': md,
  'memberId': member,
  'goals': goals,
  'assists': 1,
  'decision': decision,
  'updatedAt': updatedAt,
};

void confirm(ClubData d, String md, String member, String by) =>
    d.table('confirmation')['$md:$member:$by'] = {
      'id': '$md:$member:$by',
      'matchdayId': md,
      'memberId': member,
      'confirmerId': by,
    };

List<AlertKind> kinds(ClubData d) => [
  for (final a in clubAlerts(d, myMemberId: me, now: now)) a.kind,
];

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es');
    tzdata.initializeTimeZones();
  });

  group('jornadas nuevas', () {
    test(
      'de otro y por jugar: aviso con día, hora en la zona del servidor y lugar',
      () {
        final d = club();
        matchday(
          d,
          'md1',
          DateTime.utc(2026, 10, 10, 20),
        ); // sábado 16:00 en La Habana
        final a = clubAlerts(d, myMemberId: me, now: now).single;
        expect(a.kind, AlertKind.matchday);
        expect(a.title, 'Jornada nueva en Pachanga');
        expect(a.body, 'Sábado 10, 16:00 · El Pre. ¿Vas?');
        expect(a.matchdayId, 'md1');
      },
    );

    test('mías, ya empezadas, canceladas o en las que ya dije algo: nada', () {
      final d = club();
      matchday(d, 'mia', DateTime.utc(2026, 10, 10), by: me);
      matchday(d, 'pasada', DateTime.utc(2026, 10, 6));
      matchday(d, 'cancelada', DateTime.utc(2026, 10, 10), status: 'cancelled');
      matchday(d, 'contestada', DateTime.utc(2026, 10, 10));
      d.table('attendance')['contestada:$me'] = {
        'id': 'contestada:$me',
        'intent': 'yes',
      };
      expect(kinds(d), isEmpty);
    });
  });

  group('reportes por confirmar', () {
    ClubData base() {
      final d = club();
      matchday(d, 'md', DateTime.utc(2026, 10, 6, 20));
      played(d, 'md', me);
      report(d, 'md', 'm-yoan');
      return d;
    }

    test('jugué, no es mío y le faltan confirmaciones: aviso', () {
      final a = clubAlerts(base(), myMemberId: me, now: now).single;
      expect(a.kind, AlertKind.confirmReport);
      expect(a.title, 'Confirma lo de Yoan');
      expect(a.body, '2 goles y 1 asistencia en Pachanga. ¿Fue así?');
    });

    test(
      'si no jugué, ya lo confirmé, ya tiene bastantes o ya se decidió: nada',
      () {
        final notPlayed = base()..table('attendance').clear();
        final mine = base();
        confirm(mine, 'md', 'm-yoan', me);
        final enough = base();
        confirm(enough, 'md', 'm-yoan', 'm-pepe');
        confirm(enough, 'md', 'm-yoan', 'm-x');
        final decided = base();
        report(decided, 'md', 'm-yoan', decision: 'confirmed');
        for (final d in [notPlayed, mine, enough, decided]) {
          expect(kinds(d), isEmpty);
        }
      },
    );

    test(
      'en modo confianza, con la jornada cerrada o sin jugar todavía: nada',
      () {
        final trust = club(settings: {'reportValidation': 'trust'});
        matchday(trust, 'md', DateTime.utc(2026, 10, 6, 20));
        played(trust, 'md', me);
        report(trust, 'md', 'm-yoan');
        final closed = base();
        (closed.table('matchday')['md']!)['status'] = 'closed';
        final old = base();
        (old.table('matchday')['md']!)['startsAt'] = DateTime.utc(
          2026,
          10,
          1,
        ).toIso8601String();
        final future = base();
        (future.table('matchday')['md']!)['startsAt'] = DateTime.utc(
          2026,
          10,
          8,
        ).toIso8601String();
        for (final d in [trust, closed, old, future]) {
          expect(kinds(d), isNot(contains(AlertKind.confirmReport)));
        }
      },
    );

    test('si lo editan, es otro aviso (hay que volver a confirmarlo)', () {
      final d = base();
      final before = clubAlerts(d, myMemberId: me, now: now).single.key;
      report(d, 'md', 'm-yoan', updatedAt: 't2', goals: 3);
      expect(clubAlerts(d, myMemberId: me, now: now).single.key, isNot(before));
    });

    test('mi reporte rechazado: aviso', () {
      final d = base();
      report(d, 'md', me, decision: 'rejected');
      expect(
        kinds(d),
        containsAll([AlertKind.reportRejected, AlertKind.confirmReport]),
      );
    });
  });

  test('cuenta: mi servidor aprobado y una solicitud rechazada', () {
    final alerts = accountAlerts({
      'clubs': [
        {'id': 'c1', 'name': 'Pachanga', 'status': 'active', 'role': 'owner'},
        {'id': 'c2', 'name': 'Otra', 'status': 'active', 'role': 'player'},
      ],
      'clubRequests': [
        {
          'id': 'c3',
          'name': 'Fútbol 5',
          'status': 'rejected',
          'reviewNote': 'Ya existe',
        },
        {'id': 'c4', 'name': 'Espera', 'status': 'pending'},
      ],
    });
    expect(
      [for (final a in alerts) a.title],
      ['¡Aprobaron Pachanga!', 'No aprobaron Fútbol 5'],
    );
    expect(alerts.last.body, 'Ya existe');
  });

  group('lo ya avisado', () {
    Alert a(String key, [AlertKind kind = AlertKind.matchday]) => Alert(
      key: key,
      kind: kind,
      clubId: 'c1',
      clubName: 'P',
      title: key,
      body: '',
    );

    test(
      'la primera vez solo se marca todo (al instalar no salen veinte avisos)',
      () {
        final l = AlertLedger();
        expect(l.take([a('x'), a('y')], notify: true), isEmpty);
        expect(
          l.take([a('x'), a('y'), a('z')], notify: true).map((x) => x.key),
          ['z'],
        );
        expect(l.take([a('x'), a('y'), a('z')], notify: true), isEmpty);
      },
    );

    test('con la app a la vista se marca sin avisar', () {
      final l = AlertLedger(seeded: true);
      expect(l.take([a('x')], notify: false), isEmpty);
      expect(l.take([a('x')], notify: true), isEmpty);
    });

    test('olvida lo que ya no está, salvo lo que esta vez no se miró', () {
      final l = AlertLedger(seeded: true, seen: {'sa:1', 'md:viejo'});
      l.take([a('x')], notify: true, keep: (k) => k.startsWith('sa:'));
      expect(l.seen, {'sa:1', 'x'});
    });

    test('varios del mismo tipo y servidor van en uno', () {
      final g = grouped([
        a('1'),
        a('2'),
        a('3'),
        a('r', AlertKind.confirmReport),
      ]);
      expect([for (final x in g) x.title], ['3 jornadas nuevas en P', 'r']);
    });
  });

  test('de punta a punta con lo guardado en el teléfono', () async {
    final dir = await Directory.systemTemp.createTemp('alerts');
    addTearDown(() => dir.delete(recursive: true));
    final store = LocalStore(dir);
    await store.writeMe({
      'clubs': [
        {
          'id': 'c1',
          'name': 'Pachanga',
          'status': 'active',
          'role': 'player',
          'memberId': me,
        },
      ],
    });
    final d = club();
    await store.writeClub(d);
    // Primera vez: solo marca.
    expect(await refreshAlerts(store, notify: true, now: now), isEmpty);
    matchday(d, 'md1', DateTime.utc(2026, 10, 10, 20));
    matchday(d, 'md2', DateTime.utc(2026, 10, 11, 20));
    await store.writeClub(d);
    final fresh = await refreshAlerts(LocalStore(dir), notify: true, now: now);
    expect(fresh.single.title, '2 jornadas nuevas en Pachanga');
    expect(
      await refreshAlerts(LocalStore(dir), notify: true, now: now),
      isEmpty,
    );
  });
}
