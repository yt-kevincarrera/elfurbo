import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/data/club_repo.dart';
import 'package:elfurbo/domain/tournament/generators.dart';
import 'package:elfurbo/models/tournament.dart';
import 'package:elfurbo/models/app_user.dart';
import 'package:elfurbo/models/attendance.dart';
import 'package:elfurbo/models/match_day.dart';
import 'package:elfurbo/models/match_report.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lo que emite `ClubRepo` es exactamente `shared-fixtures/app-commands.json`,
/// y el backend valida ese mismo archivo con sus esquemas
/// (backend/test/app-commands.test.ts): si cambia un payload, fallan los dos.
void main() {
  final fixture =
      jsonDecode(File('shared-fixtures/app-commands.json').readAsStringSync())
          as Map<String, dynamic>;
  final expected = {
    for (final c in (fixture['commands'] as List).cast<Map<String, dynamic>>())
      c['name'] as String: c,
  };
  final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  final at = DateTime.utc(2026, 10, 11, 14);

  final calls = <String, Future<void> Function(ClubRepo r)>{
    'crear temporada activa': (r) => r.createSeason(
      id: '00000000-0000-4000-8000-000000000000',
      name: ' Temporada 2026 ',
      startDate: DateTime(2026),
      activate: true,
    ),
    'activar temporada': (r) => r.activateSeason('s1'),
    'editar temporada': (r) =>
        r.updateSeason('s1', name: 'Apertura', startDate: DateTime(2026, 2)),
    'cerrar temporada': (r) => r.setSeasonClosed('s1', true),
    'borrar temporada': (r) => r.deleteSeason('s1'),
    'mover jornada de temporada': (r) => r.moveMatchesToSeason(['m1'], 's2'),
    'crear jornada en una temporada': (r) => r.createMatches(
      dates: [at],
      seasonId: 's1',
      place: '  El Pre ',
      notes: '',
    ),
    'crear jornada en la temporada activa': (r) =>
        r.createMatches(dates: [at], notes: 'Traer petos'),
    'cambiar la hora y borrar el lugar': (r) => r.updateMatch(
      'm1',
      date: at.add(const Duration(minutes: 90)),
      place: '',
    ),
    'cancelar jornada': (r) => r.setMatchStatus('m1', MatchStatus.cancelled),
    'borrar jornada': (r) => r.deleteMatch('m1'),
    'guardar equipos': (r) => r.saveTeams('m1', ['p1', 'p2'], ['p3', 'g1']),
    'quitar equipos': (r) => r.clearTeams('m1'),
    'voy': (r) => r.setIntent('m1', AttendanceStatus.yes),
    'quitar intención': (r) => r.setIntent('m1', null),
    'jugué': (r) => r.setPlayed('m1', true),
    'pasar lista': (r) => r.rollCall('m1', {'p1': true, 'g1': false}),
    'mi reporte': (r) => r.submitReport(
      matchId: 'm1',
      goals: 2,
      assists: 1,
      note: 'Uno de chilena',
    ),
    'mi reporte sin comentario': (r) =>
        r.submitReport(matchId: 'm1', goals: 0, assists: 0, note: ' '),
    'goles de otro': (r) =>
        r.loadReportFor(matchId: 'm1', memberId: 'g1', goals: 3, assists: 0),
    'borrar mi reporte': (r) => r.deleteReport('m1'),
    'confirmar reporte': (r) => r.confirmReport('m1', 'p2'),
    'quitar confirmación': (r) => r.unconfirmReport('m1', 'p2'),
    'rechazar reporte': (r) =>
        r.decideReport('m1', 'p2', ReportStatus.rejected),
    'quitar decisión': (r) => r.decideReport('m1', 'p2', null),
    'corregir reporte': (r) =>
        r.correctReport('m1', 'p2', goals: 1, assists: 2),
    'votar MVP': (r) => r.castVote('m1', 'g1'),
    'quitar voto': (r) => r.clearVote('m1'),
    'cambiar apodo': (r) => r.updateNickname('p1', ' El Mago '),
    'quitar apodo': (r) => r.updateNickname('p1', ''),
    'hacer anotador': (r) => r.setRole('p1', UserRole.scorer),
    'expulsar': (r) => r.ban('p1'),
    'perdonar': (r) => r.unban('p1'),
    'cambiar ajustes': (r) =>
        r.updateSettings(reportValidation: 'trust', closeAfterHours: 48),
    'pasar el servidor': (r) => r.transferOwnership('p2'),
    'perfil del servidor': (r) => r.updateProfile(
      name: ' Los Pinos ',
      description: 'Los sábados en el Pre ',
      province: 'hab',
      city: ' Playa',
      color: 3,
    ),
    'quitar provincia y ciudad': (r) =>
        r.updateProfile(province: '', city: '  '),
    'hacer público y abierto': (r) =>
        r.setVisibility('public', joinPolicy: 'open'),
    'hacer privado': (r) => r.setVisibility('private'),
    'no compartir estadísticas': (r) => r.updateSettings(shareStats: false),
    'irme del servidor': (r) => r.leave(),
    'jugador sin cuenta': (r) => r.createGuest(' Yoandry '),
    'reglas del torneo': (r) =>
        r.updateTournament(rules: {'pointsWin': 2, 'legs': 2}, maxPlayers: 12),
    'fechas del torneo': (r) => r.updateTournament(
      registrationClosesAt: DateTime.utc(2026, 10, 31, 23, 59),
      startsOn: DateTime(2026, 11, 7),
    ),
    'sin cierre de inscripción': (r) =>
        r.updateTournament(clearRegistrationClose: true),
    'abrir inscripción': (r) => r.updateTournament(status: 'registration'),
    'formato copa': (r) => r.updateTournament(format: 'cup'),
    'inscribir equipo': (r) =>
        r.createTeam(name: ' Los Tigres ', shortName: 'tig', color: 3),
    'equipo con capitán': (r) =>
        r.createTeam(name: 'Leones', shortName: 'LEO', captainMemberId: 'p1'),
    'editar equipo': (r) => r.updateTeam('t1', name: 'Tigres FC', color: 2),
    'nuevo capitán': (r) => r.updateTeam('t1', captainMemberId: 'p2'),
    'aprobar equipo': (r) => r.setTeamStatus('t1', 'approved'),
    'añadir jugador': (r) => r.addTeamPlayer('t1', 'p2'),
    'añadir jugador con dorsal': (r) => r.addTeamPlayer('t1', 'p3', shirt: 10),
    'sacar jugador': (r) => r.removeTeamPlayer('t1', 'p2'),
    'salirme del equipo': (r) => r.leaveTeam('t1'),
    'poner dorsal': (r) => r.setShirt('t1', 'p2', 7),
    'quitar dorsal': (r) => r.setShirt('t1', 'p2', null),
    'generar liga': (r) => r.generateFixtures('league', [
      FixtureDraft(
        id: '00000000-0000-4000-8000-000000000001',
        stage: FixtureStage.league,
        round: 1,
        homeTeamId: 't1',
        awayTeamId: 't2',
        startsAt: DateTime.utc(2026, 11, 7, 19),
      ).toJson(),
    ]),
    'generar grupos': (r) => r.generateFixtures(
      'group',
      [
        FixtureDraft(
          id: '00000000-0000-4000-8000-000000000002',
          stage: FixtureStage.group,
          round: 1,
          groupLabel: 'A',
          homeTeamId: 't1',
          awayTeamId: 't2',
        ).toJson(),
      ],
      groups: {'t1': 'A', 't2': 'A'},
    ),
    'generar cuadro': (r) => r.generateFixtures('knockout', [
      FixtureDraft(
        id: '00000000-0000-4000-8000-000000000003',
        stage: FixtureStage.knockout,
        round: 2,
        slot: 0,
        homeSource: const TeamSource(
          winnerOf: '00000000-0000-4000-8000-000000000004',
        ),
        awaySource: const TeamSource(group: 'B', pos: 2),
      ).toJson(),
      FixtureDraft(
        id: '00000000-0000-4000-8000-000000000004',
        stage: FixtureStage.knockout,
        round: 1,
        slot: 0,
        homeTeamId: 't1',
        awayTeamId: 't2',
      ).toJson(),
    ]),
    'borrar calendario': (r) => r.clearFixtures('league'),
    'programar partido': (r) => r.scheduleFixture(
      'f1',
      startsAt: DateTime.utc(2026, 11, 7, 19),
      place: ' El Pre ',
      scorerMemberId: 'p1',
    ),
    'quitar anotador': (r) => r.scheduleFixture('f1', clearScorer: true),
    'resultado': (r) => r.fixtureResult(
      fixtureId: 'f1',
      homeScore: 2,
      awayScore: 1,
      events: [
        const FixtureEvent(
          id: '00000000-0000-4000-8000-000000000005',
          fixtureId: 'f1',
          teamId: 't1',
          memberId: 'p1',
          kind: EventKind.goal,
          assistMemberId: 'p2',
        ).toJson(),
        const FixtureEvent(
          id: '00000000-0000-4000-8000-000000000006',
          fixtureId: 'f1',
          teamId: 't2',
          memberId: 'p3',
          kind: EventKind.ownGoal,
        ).toJson(),
        const FixtureEvent(
          id: '00000000-0000-4000-8000-000000000007',
          fixtureId: 'f1',
          teamId: 't2',
          memberId: 'p4',
          kind: EventKind.goal,
        ).toJson(),
        const FixtureEvent(
          id: '00000000-0000-4000-8000-000000000008',
          fixtureId: 'f1',
          teamId: 't1',
          memberId: 'p1',
          kind: EventKind.mvp,
        ).toJson(),
      ],
      lineupHome: ['p1', 'p2'],
      lineupAway: ['p3', 'p4'],
    ),
    'resultado con penales': (r) => r.fixtureResult(
      fixtureId: 'f1',
      homeScore: 1,
      awayScore: 1,
      homePens: 4,
      awayPens: 3,
    ),
    'ganado sin jugar': (r) =>
        r.setFixtureStatus('f1', 'walkover', walkoverWinner: 't2'),
    'borrar resultado': (r) => r.setFixtureStatus('f1', 'scheduled'),
    'cerrar grupos': (r) =>
        r.advanceStage([(fixtureId: 'f9', homeTeamId: 't1', awayTeamId: 't4')]),
  };

  test('cada caso del fixture tiene su llamada en la app', () {
    expect(calls.keys.toSet(), expected.keys.toSet());
  });

  for (final e in calls.entries) {
    test(e.key, () async {
      final sent = <Map<String, Object?>>[];
      final repo = ClubRepo((clubId, type, payload) async {
        expect(clubId, 'c1');
        sent.add({'type': type, 'payload': payload});
      }, 'c1');
      await e.value(repo);
      expect(sent, hasLength(1));
      final payload = Map<String, Object?>.from(sent.single['payload']! as Map);
      // El id nuevo lo genera el teléfono: tiene que ser un UUID v4.
      if (expected[e.key]!['payload']['id'] == '<uuid>') {
        final id = payload['id'] as String;
        if (e.key != 'crear temporada activa') expect(id, matches(uuid));
        payload['id'] = '<uuid>';
      }
      expect(
        jsonDecode(
          jsonEncode({'type': sent.single['type'], 'payload': payload}),
        ),
        {
          'type': expected[e.key]!['type'],
          'payload': expected[e.key]!['payload'],
        },
      );
    });
  }
}
