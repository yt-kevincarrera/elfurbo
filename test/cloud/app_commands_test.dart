import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/data/club_repo.dart';
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
        r.createMatches(dates: [at], durationMinutes: 90, notes: 'Traer petos'),
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
    'jugador sin cuenta': (r) => r.createGuest(' Yoandry '),
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
