import '../cloud/sync/command.dart';
import '../models/app_user.dart';
import '../models/attendance.dart';
import '../models/match_day.dart';
import '../models/match_report.dart';

/// Encola un comando (en la app, `CloudController.run`).
typedef CommandSink =
    Future<void> Function(
      String clubId,
      String type,
      Map<String, Object?> payload,
    );

/// Los cambios de un servidor, como comandos a la cola de sync: se ven al
/// instante en la vista local y se envían cuando hay señal (spec §5). Los ids
/// de jugadores son ids de miembro. Permisos y reglas los decide el servidor;
/// si rechaza algo, aparece en "Cambios no aplicados".
///
/// Los payloads están fijados en `shared-fixtures/app-commands.json`, que el
/// backend valida con sus esquemas.
class ClubRepo {
  ClubRepo(this._send, this.clubId);

  final CommandSink _send;
  final String clubId;

  Future<void> _run(String type, Map<String, Object?> payload) =>
      _send(clubId, type, payload);

  String newId() => uuidV4();

  static String? _text(String? s) {
    final t = s?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _instant(DateTime d) => d.toUtc().toIso8601String();

  // ----------------------------------------------------------- temporadas

  Future<void> createSeason({
    required String id,
    required String name,
    required DateTime startDate,
    bool activate = false,
  }) => _run('season.create', {
    'id': id,
    'name': name.trim(),
    'startDate': _day(startDate),
    'activate': activate,
  });

  Future<void> activateSeason(String id) =>
      _run('season.activate', {'seasonId': id});

  Future<void> updateSeason(String id, {String? name, DateTime? startDate}) =>
      _run('season.update', {
        'seasonId': id,
        if (name != null) 'name': name.trim(),
        if (startDate != null) 'startDate': _day(startDate),
      });

  Future<void> setSeasonClosed(String id, bool closed) =>
      _run('season.setClosed', {'seasonId': id, 'closed': closed});

  /// El servidor solo borra temporadas sin jornadas: antes, [moveMatchesToSeason].
  Future<void> deleteSeason(String id) =>
      _run('season.delete', {'seasonId': id});

  Future<void> moveMatchesToSeason(
    Iterable<String> matchIds,
    String seasonId,
  ) async {
    for (final id in matchIds) {
      await _run('matchday.update', {'matchdayId': id, 'seasonId': seasonId});
    }
  }

  // -------------------------------------------------------------- jornadas

  /// Una jornada por fecha (repetir cada semana = varias). Sin [seasonId], va
  /// a la temporada activa.
  Future<void> createMatches({
    required List<DateTime> dates,
    String? seasonId,
    int? durationMinutes,
    String? place,
    String? notes,
  }) async {
    for (final date in dates) {
      await _run('matchday.create', {
        'id': newId(),
        'startsAt': _instant(date),
        'durationMinutes': ?durationMinutes,
        'place': _text(place),
        'notes': _text(notes),
        'seasonId': ?seasonId,
      });
    }
  }

  Future<void> updateMatch(
    String id, {
    DateTime? date,
    int? durationMinutes,
    String? seasonId,
    String? place,
    String? notes,
  }) => _run('matchday.update', {
    'matchdayId': id,
    if (date != null) 'startsAt': _instant(date),
    'durationMinutes': ?durationMinutes,
    'seasonId': ?seasonId,
    if (place != null) 'place': _text(place),
    if (notes != null) 'notes': _text(notes),
  });

  Future<void> setMatchStatus(String id, MatchStatus status) =>
      _run('matchday.setStatus', {'matchdayId': id, 'status': status.name});

  /// Borra la jornada con todo lo que cuelga de ella.
  Future<void> deleteMatch(String id) =>
      _run('matchday.delete', {'matchdayId': id});

  Future<void> saveTeams(
    String matchId,
    List<String> teamA,
    List<String> teamB,
  ) => _run('teams.save', {
    'matchdayId': matchId,
    'teams': {'a': teamA, 'b': teamB},
  });

  Future<void> clearTeams(String matchId) =>
      _run('teams.save', {'matchdayId': matchId, 'teams': null});

  // ------------------------------------------------------------ asistencia

  /// Mi intención (Voy / Quizás / No voy), o null para quitarla.
  Future<void> setIntent(String matchId, AttendanceStatus? status) => _run(
    'attendance.setIntent',
    {'matchdayId': matchId, 'intent': status?.name},
  );

  /// "Jugué" / "No fui" (mío).
  Future<void> setPlayed(String matchId, bool played) =>
      _run('attendance.setPlayed', {'matchdayId': matchId, 'played': played});

  /// Pasar lista (staff): quién jugó y quién no.
  Future<void> rollCall(String matchId, Map<String, bool> played) => _run(
    'attendance.rollCall',
    {
      'matchdayId': matchId,
      'entries': [
        for (final e in played.entries) {'memberId': e.key, 'played': e.value},
      ],
    },
  );

  // -------------------------------------------------------------- reportes

  /// Mi reporte (crear o editar). Cuenta como "Jugué".
  Future<void> submitReport({
    required String matchId,
    required int goals,
    required int assists,
    String? note,
  }) => _run('report.upsert', {
    'matchdayId': matchId,
    'goals': goals,
    'assists': assists,
    'note': _text(note),
  });

  /// El staff pone el reporte de otro (también de un jugador sin cuenta).
  Future<void> loadReportFor({
    required String matchId,
    required String memberId,
    required int goals,
    required int assists,
    String? note,
  }) => _run('report.loadFor', {
    'matchdayId': matchId,
    'memberId': memberId,
    'goals': goals,
    'assists': assists,
    'note': _text(note),
  });

  /// Borra mi reporte.
  Future<void> deleteReport(String matchId) =>
      _run('report.delete', {'matchdayId': matchId});

  Future<void> confirmReport(String matchId, String authorId) =>
      _run('report.confirm', {'matchdayId': matchId, 'memberId': authorId});

  Future<void> unconfirmReport(String matchId, String authorId) =>
      _run('report.unconfirm', {'matchdayId': matchId, 'memberId': authorId});

  /// owner o admin: confirmar, rechazar o quitar la decisión (null).
  Future<void> decideReport(
    String matchId,
    String authorId,
    ReportStatus? decision,
  ) => _run('report.decide', {
    'matchdayId': matchId,
    'memberId': authorId,
    'decision': switch (decision) {
      ReportStatus.confirmed => 'confirmed',
      ReportStatus.rejected => 'rejected',
      _ => null,
    },
  });

  /// owner o admin corrigen los números: queda confirmado.
  Future<void> correctReport(
    String matchId,
    String authorId, {
    required int goals,
    required int assists,
  }) => _run('report.correct', {
    'matchdayId': matchId,
    'memberId': authorId,
    'goals': goals,
    'assists': assists,
  });

  // ------------------------------------------------------------------- MVP

  Future<void> castVote(String matchId, String votedFor) =>
      _run('vote.cast', {'matchdayId': matchId, 'votedFor': votedFor});

  Future<void> clearVote(String matchId) =>
      _run('vote.clear', {'matchdayId': matchId});

  // -------------------------------------------------------------- miembros

  Future<void> updateNickname(String memberId, String nickname) => _run(
    'member.update',
    {'memberId': memberId, 'nickname': _text(nickname)},
  );

  Future<void> setRole(String memberId, UserRole role) =>
      _run('member.setRole', {'memberId': memberId, 'role': role.name});

  Future<void> ban(String memberId) =>
      _run('member.ban', {'memberId': memberId});

  Future<void> unban(String memberId) =>
      _run('member.unban', {'memberId': memberId});

  /// Ajustes del servidor (solo lo que cambia). Solo el dueño.
  Future<void> updateSettings({
    String? matchdayCreators,
    String? reportValidation,
    int? confirmationsNeeded,
    int? closeAfterHours,
    bool? shareStats,
  }) => _run('club.updateSettings', {
    'matchdayCreators': ?matchdayCreators,
    'reportValidation': ?reportValidation,
    'confirmationsNeeded': ?confirmationsNeeded,
    'closeAfterHours': ?closeAfterHours,
    'shareStats': ?shareStats,
  });

  /// Nombre, descripción, provincia, ciudad y color (solo lo que cambia). Solo
  /// el dueño. Una provincia o ciudad vacía ('') se quita.
  Future<void> updateProfile({
    String? name,
    String? description,
    String? province,
    String? city,
    int? color,
  }) => _run('club.updateProfile', {
    if (name != null) 'name': name.trim(),
    if (description != null) 'description': description.trim(),
    if (province != null) 'province': province.isEmpty ? null : province,
    if (city != null) 'city': _text(city),
    'color': ?color,
  });

  /// Privado (solo por invitación) o público (sale en el directorio). En uno
  /// público, [joinPolicy] dice si entrar se pide (`request`) o es al momento
  /// (`open`). Solo el dueño.
  Future<void> setVisibility(String visibility, {String? joinPolicy}) => _run(
    'club.setVisibility',
    {'visibility': visibility, 'joinPolicy': ?joinPolicy},
  );

  /// El dueño le pasa el servidor a otro miembro con cuenta (él queda de admin).
  Future<void> transferOwnership(String memberId) =>
      _run('club.transferOwnership', {'memberId': memberId});

  /// Me voy de este servidor (el dueño antes tiene que pasárselo a otro).
  Future<void> leave() => _run('member.leave', {});

  /// Un jugador sin cuenta (lo puede reclamar después con una invitación).
  /// Devuelve su id, para ponerle los goles enseguida (va en la misma cola).
  Future<String> createGuest(String displayName) async {
    final id = newId();
    await _run('member.createGuest', {
      'id': id,
      'displayName': displayName.trim(),
    });
    return id;
  }

  // --------------------------------------------------------------- torneos

  /// Cambios del torneo (solo lo que cambia). Organizadores.
  Future<void> updateTournament({
    String? format,
    Map<String, Object?>? rules,
    DateTime? registrationClosesAt,
    bool clearRegistrationClose = false,
    DateTime? startsOn,
    int? maxTeams,
    int? minPlayers,
    int? maxPlayers,
    String? status,
  }) => _run('tournament.update', {
    'format': ?format,
    'rules': ?rules,
    if (clearRegistrationClose)
      'registrationClosesAt': null
    else if (registrationClosesAt != null)
      'registrationClosesAt': _instant(registrationClosesAt),
    if (startsOn != null) 'startsOn': _day(startsOn),
    'maxTeams': ?maxTeams,
    'minPlayers': ?minPlayers,
    'maxPlayers': ?maxPlayers,
    'status': ?status,
  });

  /// Inscribe un equipo. Devuelve su id (para abrirlo enseguida).
  Future<String> createTeam({
    required String name,
    required String shortName,
    int color = 0,
    String? captainMemberId,
    String? representsClubId,
  }) async {
    final id = newId();
    await _run('team.create', {
      'id': id,
      'name': name.trim(),
      'shortName': shortName.trim().toUpperCase(),
      'color': color,
      'captainMemberId': ?captainMemberId,
      'representsClubId': ?representsClubId,
    });
    return id;
  }

  Future<void> updateTeam(
    String teamId, {
    String? name,
    String? shortName,
    int? color,
    String? captainMemberId,
  }) => _run('team.update', {
    'teamId': teamId,
    if (name != null) 'name': name.trim(),
    if (shortName != null) 'shortName': shortName.trim().toUpperCase(),
    'color': ?color,
    'captainMemberId': ?captainMemberId,
  });

  /// `approved`, `pending` o `withdrawn`.
  Future<void> setTeamStatus(String teamId, String status) =>
      _run('team.setStatus', {'teamId': teamId, 'status': status});

  Future<void> addTeamPlayer(String teamId, String memberId, {int? shirt}) =>
      _run('team.addPlayer', {
        'teamId': teamId,
        'memberId': memberId,
        'shirt': ?shirt,
      });

  Future<void> removeTeamPlayer(String teamId, String memberId) =>
      _run('team.removePlayer', {'teamId': teamId, 'memberId': memberId});

  Future<void> leaveTeam(String teamId) =>
      _run('team.leave', {'teamId': teamId});

  Future<void> setShirt(String teamId, String memberId, int? shirt) => _run(
    'team.setShirt',
    {'teamId': teamId, 'memberId': memberId, 'shirt': shirt},
  );

  // ------------------------------------------------------------- partidos

  /// El calendario de una fase (`league`, `group` o `knockout`). En grupos,
  /// [groups] dice el grupo de cada equipo.
  Future<void> generateFixtures(
    String stage,
    List<Map<String, Object?>> fixtures, {
    Map<String, String>? groups,
  }) => _run('fixtures.generate', {
    'stage': stage,
    'fixtures': fixtures,
    if (groups != null)
      'groups': [
        for (final e in groups.entries)
          {'teamId': e.key, 'groupLabel': e.value},
      ],
  });

  Future<void> clearFixtures(String stage) =>
      _run('fixtures.clear', {'stage': stage});

  /// Fecha, terreno y anotador (solo lo que cambia; '' quita el terreno).
  Future<void> scheduleFixture(
    String fixtureId, {
    DateTime? startsAt,
    String? place,
    String? scorerMemberId,
    bool clearScorer = false,
  }) => _run('fixture.schedule', {
    'fixtureId': fixtureId,
    if (startsAt != null) 'startsAt': _instant(startsAt),
    if (place != null) 'place': _text(place),
    if (clearScorer)
      'scorerMemberId': null
    else if (scorerMemberId != null)
      'scorerMemberId': scorerMemberId,
  });

  /// El resultado con su detalle (eventos y quién jugó).
  Future<void> fixtureResult({
    required String fixtureId,
    required int homeScore,
    required int awayScore,
    int? homePens,
    int? awayPens,
    List<Map<String, Object?>> events = const [],
    List<String> lineupHome = const [],
    List<String> lineupAway = const [],
  }) => _run('fixture.result', {
    'fixtureId': fixtureId,
    'homeScore': homeScore,
    'awayScore': awayScore,
    'homePens': ?homePens,
    'awayPens': ?awayPens,
    'events': events,
    'lineups': {'home': lineupHome, 'away': lineupAway},
  });

  /// `scheduled` (borra el resultado), `cancelled` o `walkover` (con el que gana).
  Future<void> setFixtureStatus(
    String fixtureId,
    String status, {
    String? walkoverWinner,
  }) => _run('fixture.setStatus', {
    'fixtureId': fixtureId,
    'status': status,
    'walkoverWinner': ?walkoverWinner,
  });

  /// De los grupos al cuadro: qué equipos van en cada partido.
  Future<void> advanceStage(
    List<({String fixtureId, String? homeTeamId, String? awayTeamId})>
    assignments,
  ) => _run('stage.advance', {
    'assignments': [
      for (final a in assignments)
        {
          'fixtureId': a.fixtureId,
          'homeTeamId': ?a.homeTeamId,
          'awayTeamId': ?a.awayTeamId,
        },
    ],
  });

  /// Terminar el torneo con sus premios (`{kind, teamId?, memberId?, value?}`).
  Future<void> finishTournament(List<Map<String, Object?>> awards) =>
      _run('tournament.finish', {'awards': awards});

  /// Reabrir un torneo terminado (se quitan los premios).
  Future<void> reopenTournament() => _run('tournament.reopen', {});
}
