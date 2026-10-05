import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/state/providers.dart';
import 'package:elfurbo/cloud/sync/club_data.dart';
import 'package:elfurbo/cloud/sync/command.dart';
import 'package:elfurbo/cloud/sync/reducers.dart';
import 'package:elfurbo/data/club_repo.dart';
import 'package:elfurbo/data/providers.dart';
import 'package:elfurbo/models/attendance.dart';
import 'package:elfurbo/models/match_day.dart';
import 'package:elfurbo/models/match_report.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un servidor como llega del pull: dueño, anotador, dos jugadores, uno sin
/// cuenta, la temporada activa y una jornada que ya se jugó.
ClubData _server({Map<String, Object?> settings = const {}}) {
  final d = ClubData(clubId: 'c1');
  d.table('club')['c1'] = {
    'id': 'c1',
    'name': 'Unción y Fuego',
    'status': 'active',
    'settings': {
      'matchdayCreators': 'members',
      'reportValidation': 'confirm',
      'confirmationsNeeded': 2,
      'closeAfterHours': 72,
      ...settings,
    },
  };
  for (final (id, role, user) in [
    ('k', 'owner', 'u-k'),
    ('s1', 'scorer', 'u-s'),
    ('p1', 'player', 'u-1'),
    ('p2', 'player', 'u-2'),
    ('p3', 'player', 'u-3'),
    ('g1', 'guest', null),
  ]) {
    d.table('member')[id] = {
      'id': id,
      'userId': user,
      'role': role,
      'status': 'active',
      'displayName': id,
      'nickname': null,
    };
  }
  d.table('season')['s1'] = {
    'id': 's1',
    'name': '2026',
    'startDate': '2026-01-01',
    'isActive': true,
    'isClosed': false,
  };
  d.table('matchday')['m1'] = {
    'id': 'm1',
    'seasonId': 's1',
    'startsAt': DateTime.now()
        .subtract(const Duration(hours: 5))
        .toUtc()
        .toIso8601String(),
    'durationMinutes': 120,
    'place': null,
    'notes': null,
    'status': 'scheduled',
    'teams': null,
    'createdBy': 'k',
  };
  return d;
}

/// Aplica lo que hace [member] con el repo encima de [d], como en su teléfono.
Future<ClubData> _as(
  String member,
  ClubData d,
  Future<void> Function(ClubRepo r) act,
) async {
  final cmds = <Command>[];
  await act(
    ClubRepo((clubId, type, payload) async {
      cmds.add(Command.create(clubId, type, payload));
    }, 'c1'),
  );
  return clubView(d, cmds, myMemberId: member);
}

ProviderContainer _container(
  ClubData view, {
  String me = 'p1',
  String role = 'player',
}) => ProviderContainer(
  overrides: [
    currentClubProvider.overrideWithValue(
      MyClub(
        id: 'c1',
        name: 'Unción y Fuego',
        status: 'active',
        memberId: me,
        role: role,
      ),
    ),
    clubDataProvider.overrideWithValue(AsyncData(view)),
  ],
);

void main() {
  test(
    'sin señal: un jugador crea la jornada y dice que va; se ve al instante',
    () async {
      final at = DateTime.now().add(const Duration(days: 3));
      var d = await _as(
        'p1',
        _server(),
        (r) => r.createMatches(dates: [at], place: 'El Pre'),
      );
      final id =
          d.all('matchday').firstWhere((m) => m['id'] != 'm1')['id'] as String;
      d = await _as('p1', d, (r) => r.setIntent(id, AttendanceStatus.yes));
      final c = _container(d);
      final match = c.read(matchByIdProvider(id))!;
      expect(match.seasonId, 's1', reason: 'va a la temporada activa');
      expect(match.createdBy, 'p1');
      expect(match.place, 'El Pre');
      expect(match.isUpcoming(DateTime.now()), isTrue);
      expect(
        c.read(attendanceForMatchProvider(id))['p1']!.status,
        AttendanceStatus.yes,
      );
      expect(c.read(canCreateMatchdayProvider), isTrue);
    },
  );

  test(
    'un reporte cuenta con dos confirmaciones de compañeros que jugaron',
    () async {
      var d = await _as(
        'p1',
        _server(),
        (r) => r.submitReport(matchId: 'm1', goals: 2, assists: 1),
      );
      // p2 confirma sin haber marcado "Jugué": no vale todavía.
      d = await _as('p2', d, (r) => r.confirmReport('m1', 'p1'));
      MatchReport report(ClubData d) =>
          _container(d).read(reportsForMatchProvider('m1')).single;
      expect(_container(d).read(iAmPresentProvider('m1')), isTrue);
      expect(report(d).confirmations, isEmpty);
      d = await _as('p2', d, (r) => r.setPlayed('m1', true));
      expect(report(d).confirmations, ['p2']);
      expect(report(d).isPending, isTrue);
      expect(report(d).confirmationsMissing, 1);
      d = await _as('p3', d, (r) async {
        await r.setPlayed('m1', true);
        await r.confirmReport('m1', 'p1');
      });
      expect(report(d).isConfirmed, isTrue);
      expect(_container(d).read(statsProvider).statsOf('p1').goals, 2);

      // Editarlo lo vuelve pendiente: las confirmaciones se borran.
      d = await _as(
        'p1',
        d,
        (r) => r.submitReport(matchId: 'm1', goals: 3, assists: 1),
      );
      expect(report(d).confirmations, isEmpty);
      expect(report(d).isPending, isTrue);
      expect(_container(d).read(statsProvider).statsOf('p1').goals, 0);
    },
  );

  test(
    'lo que pone el staff cuenta al momento, también para un jugador sin cuenta',
    () async {
      final d = await _as(
        's1',
        _server(),
        (r) => r.loadReportFor(
          matchId: 'm1',
          memberId: 'g1',
          goals: 3,
          assists: 0,
        ),
      );
      final c = _container(d, me: 's1', role: 'scorer');
      final report = c.read(reportsForMatchProvider('m1')).single;
      expect(report.uid, 'g1');
      expect(report.loadedBy, 's1');
      expect(report.isConfirmed, isTrue);
      expect(c.read(presentUidsProvider('m1')), contains('g1'));
      expect(c.read(statsProvider).statsOf('g1').goals, 3);
      expect(c.read(isStaffProvider), isTrue);
      expect(c.read(isAdminProvider), isFalse);
    },
  );

  test(
    'servidor en "trust": cuenta sin confirmaciones; un rechazo gana siempre',
    () async {
      var d = await _as(
        'p1',
        _server(settings: {'reportValidation': 'trust'}),
        (r) => r.submitReport(matchId: 'm1', goals: 1, assists: 0),
      );
      MatchReport report() =>
          _container(d).read(reportsForMatchProvider('m1')).single;
      expect(report().isConfirmed, isTrue);
      d = await _as(
        'k',
        d,
        (r) => r.decideReport('m1', 'p1', ReportStatus.rejected),
      );
      expect(report().isRejected, isTrue);
      expect(report().authorCanEdit, isFalse);
      d = await _as(
        'k',
        d,
        (r) => r.correctReport('m1', 'p1', goals: 4, assists: 4),
      );
      expect(report().goals, 4);
      expect(report().correctedByAdmin, isTrue);
      expect(report().isConfirmed, isTrue);
    },
  );

  test('pasar lista, votar y quitar el voto', () async {
    var d = await _as(
      's1',
      _server(),
      (r) => r.rollCall('m1', {'p1': true, 'g1': true, 'p2': false}),
    );
    var c = _container(d);
    expect(c.read(presentUidsProvider('m1')), {'p1', 'g1'});
    expect(c.read(attendanceForMatchProvider('m1'))['p2']!.isAbsent, isTrue);
    d = await _as('p1', d, (r) => r.castVote('m1', 'g1'));
    c = _container(d);
    expect(c.read(votesForMatchProvider('m1')).single.votedFor, 'g1');
    d = await _as('p1', d, (r) => r.clearVote('m1'));
    expect(_container(d).read(votesForMatchProvider('m1')), isEmpty);
  });

  test('borrar una jornada se lleva todo lo que cuelga de ella', () async {
    var d = await _as('p1', _server(), (r) async {
      await r.submitReport(matchId: 'm1', goals: 1, assists: 1);
    });
    d = await _as('p2', d, (r) async {
      await r.setPlayed('m1', true);
      await r.confirmReport('m1', 'p1');
      await r.castVote('m1', 'p1');
    });
    d = await _as('k', d, (r) => r.deleteMatch('m1'));
    for (final t in const [
      'matchday',
      'attendance',
      'report',
      'confirmation',
      'vote',
    ]) {
      expect(d.all(t), isEmpty, reason: t);
    }
  });

  test(
    'estado, equipos y cierre: una jornada cerrada no acepta cambios en la app',
    () async {
      var d = await _as(
        'k',
        _server(),
        (r) => r.saveTeams('m1', ['p1', 'p2'], ['p3', 'g1']),
      );
      var c = _container(d);
      expect(c.read(matchByIdProvider('m1'))!.teamB, ['p3', 'g1']);
      expect(c.read(matchClosedProvider('m1')), isFalse);
      d = await _as('k', d, (r) => r.setMatchStatus('m1', MatchStatus.closed));
      c = _container(d);
      expect(c.read(matchClosedProvider('m1')), isTrue);
      // El plazo sale de los ajustes del servidor, no de las 72 h fijas.
      c = _container(_server(settings: {'closeAfterHours': 4}));
      expect(c.read(matchClosedProvider('m1')), isTrue);
    },
  );

  test(
    'si el servidor solo deja crear jornadas al staff, un jugador no ve el botón',
    () {
      final d = _server(settings: {'matchdayCreators': 'staff'});
      expect(_container(d).read(canCreateMatchdayProvider), isFalse);
      expect(
        _container(d, me: 's1', role: 'scorer').read(canCreateMatchdayProvider),
        isTrue,
      );
    },
  );

  test(
    'lo que puso el staff sigue contando aunque luego le cambien el rol, y al revés',
    () async {
      var d = await _as(
        's1',
        _server(),
        (r) => r.loadReportFor(
          matchId: 'm1',
          memberId: 'g1',
          goals: 2,
          assists: 0,
        ),
      );
      d = await _as(
        'p1',
        d,
        (r) => r.submitReport(matchId: 'm1', goals: 1, assists: 0),
      );
      // El anotador pasa a jugador y el jugador a anotador.
      d.one('member', 's1')!['role'] = 'player';
      d.one('member', 'p1')!['role'] = 'scorer';
      final reports = {
        for (final r in _container(d).read(reportsForMatchProvider('m1')))
          r.uid: r,
      };
      expect(reports['g1']!.isConfirmed, isTrue);
      expect(reports['p1']!.isPending, isTrue);
    },
  );
}
