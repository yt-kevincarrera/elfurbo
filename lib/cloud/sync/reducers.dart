import 'club_data.dart';
import '../../domain/tournament/knockout.dart';
import '../../models/tournament.dart';
import 'command.dart';

/// La vista de un servidor: el último estado del servidor con los comandos
/// pendientes aplicados encima, en orden. Así un cambio hecho sin señal se ve
/// al instante y no se pierde cuando llega un pull (spec §5).
///
/// No comprueba permisos ni reglas: eso lo decide el servidor. Si rechaza un
/// comando, sale de la cola y la vista vuelve sola al estado del servidor.
ClubData clubView(
  ClubData server,
  Iterable<Command> pending, {
  required String? myMemberId,
}) {
  final view = server.copy();
  for (final c in pending) {
    if (c.clubId == server.clubId) {
      applyCommand(view, c, myMemberId: myMemberId);
    }
  }
  return view;
}

/// Aplica un comando sobre `d` (que ya es una copia). Un tipo desconocido no hace nada.
void applyCommand(ClubData d, Command c, {required String? myMemberId}) {
  final p = c.payload;
  Row? member(Object? id) => d.one('member', '$id');
  switch (c.type) {
    case 'member.createGuest':
      d.table('member')['${p['id']}'] = {
        'id': p['id'],
        'userId': null,
        'role': 'guest',
        'status': 'active',
        'displayName': p['displayName'],
        'nickname': p['nickname'],
        'claimedAt': null,
      };
    case 'member.update':
      final m = member(p['memberId']);
      if (m == null) return;
      if (p.containsKey('displayName')) m['displayName'] = p['displayName'];
      if (p.containsKey('nickname')) m['nickname'] = p['nickname'];
    case 'member.setRole':
      member(p['memberId'])?['role'] = p['role'];
    case 'member.ban':
      member(p['memberId'])?['status'] = 'banned';
      _releaseFromTeams(d, '${p['memberId']}');
    case 'member.unban':
      member(p['memberId'])?['status'] = 'left';
    case 'member.leave':
      if (myMemberId != null) {
        member(myMemberId)?['status'] = 'left';
        _releaseFromTeams(d, myMemberId);
      }
    case 'club.updateSettings':
      final club = d.club;
      if (club == null) return;
      club['settings'] = {...(club['settings'] as Map? ?? const {}), ...p};
    case 'club.updateProfile':
      final club = d.club;
      if (club == null) return;
      for (final f in const ['name', 'description', 'province', 'city']) {
        if (p.containsKey(f)) club[f] = p[f];
      }
      if (p.containsKey('color')) club['color'] = p['color'];
    case 'club.setVisibility':
      final club = d.club;
      // Fuera del directorio no puede ser público (el servidor lo rechaza).
      if (club == null ||
          (p['visibility'] == 'public' && club['delisted'] == true)) {
        return;
      }
      club['visibility'] = p['visibility'];
      if (p['joinPolicy'] != null) {
        club['settings'] = {
          ...(club['settings'] as Map? ?? const {}),
          'joinPolicy': p['joinPolicy'],
        };
      }
    case 'club.transferOwnership':
      final target = member(p['memberId']);
      if (target == null) return;
      for (final m in d.all('member')) {
        if (m['role'] == 'owner') m['role'] = 'admin';
      }
      target['role'] = 'owner';
    case 'season.create':
      if (p['activate'] == true) _deactivateSeasons(d);
      d.table('season')['${p['id']}'] = {
        'id': p['id'],
        'name': p['name'],
        'startDate': p['startDate'],
        'isActive': p['activate'] == true,
        'isClosed': false,
      };
    case 'season.update':
      final s = d.one('season', '${p['seasonId']}');
      if (s == null) return;
      if (p['name'] != null) s['name'] = p['name'];
      if (p['startDate'] != null) s['startDate'] = p['startDate'];
    case 'season.activate':
      final s = d.one('season', '${p['seasonId']}');
      if (s == null || s['isClosed'] == true) return;
      _deactivateSeasons(d);
      s['isActive'] = true;
    case 'season.setClosed':
      final s = d.one('season', '${p['seasonId']}');
      if (s == null) return;
      s['isClosed'] = p['closed'] == true;
      if (p['closed'] == true) s['isActive'] = false;
    case 'season.delete':
      d.table('season').remove('${p['seasonId']}');
    default:
      if (c.type.startsWith('fixture') || c.type.startsWith('stage.')) {
        _applyFixtures(d, c, myMemberId);
      } else if (c.type.startsWith('team.') ||
          c.type.startsWith('tournament.')) {
        _applyTournament(d, c, myMemberId);
      } else {
        _applyPachanga(d, c, myMemberId);
      }
  }
}

/// Torneo, equipos y plantillas (ids de plantilla: `equipo:miembro`, como el
/// servidor).
void _applyTournament(ClubData d, Command c, String? me) {
  final p = c.payload;
  final myRole = me == null ? null : d.one('member', me)?['role'];
  final organizer = const {'owner', 'admin'}.contains(myRole);
  Row? team() => d.one('team', '${p['teamId']}');
  String playerKey(Object? team, Object? member) => '$team:$member';

  void addPlayer(Object? teamId, Object? memberId, Object? shirt) {
    final id = playerKey(teamId, memberId);
    final previous = d.one('teamPlayer', id);
    d.table('teamPlayer')[id] = {
      'id': id,
      'teamId': '$teamId',
      'memberId': '$memberId',
      'shirt': shirt ?? previous?['shirt'],
      'status': 'active',
    };
  }

  switch (c.type) {
    case 'tournament.update':
      final t = d.one('tournament', d.clubId);
      if (t == null) return;
      for (final f in const [
        'format',
        'registrationClosesAt',
        'startsOn',
        'maxTeams',
        'minPlayers',
        'maxPlayers',
        'status',
      ]) {
        if (p.containsKey(f)) t[f] = p[f];
      }
      if (p['rules'] is Map) {
        t['rules'] = {
          ...(t['rules'] as Map? ?? const {}),
          ...(p['rules'] as Map),
        };
      }
    case 'team.create':
      final captain = organizer ? p['captainMemberId'] : me;
      d.table('team')['${p['id']}'] = {
        'id': p['id'],
        'name': p['name'],
        'shortName': p['shortName'],
        'color': p['color'] ?? 0,
        'captainMemberId': captain,
        'representsClubId': p['representsClubId'],
        'status': organizer ? 'approved' : 'pending',
        'seed': null,
        'groupLabel': null,
      };
      if (captain != null) addPlayer(p['id'], captain, null);
    case 'team.update':
      final t = team();
      if (t == null) return;
      for (final f in const [
        'name',
        'shortName',
        'color',
        'captainMemberId',
        'representsClubId',
      ]) {
        if (p.containsKey(f)) t[f] = p[f];
      }
    case 'team.setStatus':
      final t = team();
      if (t == null) return;
      t['status'] = p['status'];
      if (p['status'] == 'withdrawn') {
        for (final tp in d.all('teamPlayer')) {
          if (tp['teamId'] == t['id']) tp['status'] = 'removed';
        }
      }
    case 'team.addPlayer':
      addPlayer(p['teamId'], p['memberId'], p['shirt']);
    case 'team.removePlayer':
      d.one('teamPlayer', playerKey(p['teamId'], p['memberId']))?['status'] =
          'removed';
    case 'team.leave':
      d.one('teamPlayer', playerKey(p['teamId'], me))?['status'] = 'removed';
    case 'team.setShirt':
      d.one('teamPlayer', playerKey(p['teamId'], p['memberId']))?['shirt'] =
          p['shirt'];
  }
}

/// Jornadas, asistencia, reportes, confirmaciones y votos. Los ids son los
/// del servidor: `jornada:miembro` (y `jornada:autor:confirmador`).
void _applyPachanga(ClubData d, Command c, String? me) {
  final p = c.payload;
  final mdId = '${p['matchdayId']}';
  Row? matchday() => d.one('matchday', mdId);
  String key(Object? member) => '$mdId:$member';

  Row attendance(Object? member) => d
      .table('attendance')
      .putIfAbsent(
        key(member),
        () => {
          'id': key(member),
          'matchdayId': mdId,
          'memberId': '$member',
          'intent': null,
          'played': null,
          'playedSetBy': null,
        },
      );

  void clearConfirmations(Object? member) => d
      .table('confirmation')
      .removeWhere(
        (_, r) => r['matchdayId'] == mdId && r['memberId'] == '$member',
      );

  // Lo que pone el staff queda confirmado en el reporte (como en el servidor).
  final myRole = me == null ? null : d.one('member', me)?['role'];
  final staff = const {'owner', 'admin', 'scorer'}.contains(myRole);

  void writeReport(Object? member) {
    clearConfirmations(member);
    d.table('report')[key(member)] = {
      'id': key(member),
      'matchdayId': mdId,
      'memberId': '$member',
      'goals': p['goals'],
      'assists': p['assists'],
      'note': p['note'],
      'loadedBy': me,
      'decision': staff ? 'confirmed' : null,
      'correctedBy': null,
    };
    attendance(member)
      ..['played'] = true
      ..['playedSetBy'] = me;
  }

  switch (c.type) {
    case 'matchday.create':
      final active = d.all('season').where((s) => s['isActive'] == true);
      d.table('matchday')['${p['id']}'] = {
        'id': p['id'],
        'seasonId': p['seasonId'] ?? active.firstOrNull?['id'],
        'startsAt': p['startsAt'],
        'durationMinutes': p['durationMinutes'] ?? 0,
        'place': p['place'],
        'notes': p['notes'],
        'status': 'scheduled',
        'teams': null,
        'createdBy': me,
      };
    case 'matchday.update':
      final md = matchday();
      if (md == null) return;
      for (final f in const [
        'startsAt',
        'durationMinutes',
        'place',
        'notes',
        'seasonId',
      ]) {
        if (p.containsKey(f)) md[f] = p[f];
      }
    case 'matchday.setStatus':
      matchday()?['status'] = p['status'];
    case 'matchday.delete':
      d.table('matchday').remove(mdId);
      for (final t in const ['attendance', 'report', 'confirmation', 'vote']) {
        d.table(t).removeWhere((_, r) => r['matchdayId'] == mdId);
      }
    case 'teams.save':
      matchday()?['teams'] = p['teams'];
    case 'attendance.setIntent':
      if (me != null) attendance(me)['intent'] = p['intent'];
    case 'attendance.setPlayed':
      if (me != null) {
        attendance(me)
          ..['played'] = p['played']
          ..['playedSetBy'] = me;
      }
    case 'attendance.rollCall':
      for (final e in (p['entries'] as List? ?? const [])) {
        attendance((e as Map)['memberId'])
          ..['played'] = e['played']
          ..['playedSetBy'] = me;
      }
    case 'report.upsert':
      if (me != null) writeReport(me);
    case 'report.loadFor':
      writeReport(p['memberId']);
    case 'report.delete':
      if (me == null) return;
      clearConfirmations(me);
      d.table('report').remove(key(me));
    case 'report.confirm':
      if (me == null) return;
      final id = '${key(p['memberId'])}:$me';
      d.table('confirmation')[id] = {
        'id': id,
        'matchdayId': mdId,
        'memberId': p['memberId'],
        'confirmerId': me,
      };
    case 'report.unconfirm':
      d.table('confirmation').remove('${key(p['memberId'])}:$me');
    case 'report.decide':
      d.one('report', key(p['memberId']))?['decision'] = p['decision'];
    case 'report.correct':
      final r = d.one('report', key(p['memberId']));
      if (r == null) return;
      r
        ..['goals'] = p['goals']
        ..['assists'] = p['assists']
        ..['decision'] = 'confirmed'
        ..['correctedBy'] = me;
    case 'vote.cast':
      if (me == null) return;
      d.table('vote')[key(me)] = {
        'id': key(me),
        'matchdayId': mdId,
        'voterId': me,
        'votedFor': p['votedFor'],
      };
    case 'vote.clear':
      d.table('vote').remove(key(me));
  }
}

void _deactivateSeasons(ClubData d) {
  for (final s in d.all('season')) {
    s['isActive'] = false;
  }
}

/// En un torneo, quien se va o es expulsado deja su equipo (y la capitanía),
/// como en el servidor.
void _releaseFromTeams(ClubData d, String memberId) {
  for (final tp in d.all('teamPlayer')) {
    if (tp['memberId'] == memberId) tp['status'] = 'removed';
  }
  for (final t in d.all('team')) {
    if (t['captainMemberId'] == memberId) t['captainMemberId'] = null;
  }
}

const _families = {
  'league': {'league'},
  'group': {'group'},
  'knockout': {'knockout', 'third'},
};

/// Calendario, resultados y el paso de los grupos al cuadro. Como el
/// servidor: un resultado de eliminatoria pone al que pasa en el partido
/// siguiente (`knockout.dart`).
void _applyFixtures(ClubData d, Command c, String? me) {
  final p = c.payload;
  Row? fixture() => d.one('fixture', '${p['fixtureId']}');

  void clearDetail(String fixtureId) {
    d.table('fixtureEvent').removeWhere((_, e) => e['fixtureId'] == fixtureId);
    d.table('fixtureLineup').removeWhere((_, l) => l['fixtureId'] == fixtureId);
  }

  void propagate(Row f) {
    final decided = Fixture.fromCloud(f.cast<String, dynamic>());
    final all = [
      for (final r in d.all('fixture'))
        Fixture.fromCloud(r.cast<String, dynamic>()),
    ];
    for (final (id, side, team) in dependents(decided, all)) {
      final next = d.one('fixture', id);
      // Uno ya jugado no cambia (el servidor rechaza la corrección).
      if (next == null ||
          next['status'] == 'played' ||
          next['status'] == 'walkover') {
        continue;
      }
      next['${side}TeamId'] = team;
    }
  }

  switch (c.type) {
    case 'fixtures.generate':
      for (final raw in (p['fixtures'] as List? ?? const [])) {
        final f = Map<String, Object?>.from(raw as Map);
        d.table('fixture')['${f['id']}'] = {
          'id': f['id'],
          'stage': f['stage'],
          'round': f['round'],
          'groupLabel': f['groupLabel'],
          'leg': f['leg'] ?? 1,
          'slot': f['slot'],
          'homeTeamId': f['homeTeamId'],
          'awayTeamId': f['awayTeamId'],
          'homeSource': f['homeSource'],
          'awaySource': f['awaySource'],
          'startsAt': f['startsAt'],
          'place': null,
          'scorerMemberId': null,
          'status': 'scheduled',
          'homeScore': null,
          'awayScore': null,
          'homePens': null,
          'awayPens': null,
          'walkoverWinner': null,
        };
      }
      for (final g in (p['groups'] as List? ?? const [])) {
        d.one('team', '${(g as Map)['teamId']}')?['groupLabel'] =
            g['groupLabel'];
      }
    case 'fixtures.clear':
      final family = _families[p['stage']] ?? const <String>{};
      d.table('fixture').removeWhere((_, f) => family.contains(f['stage']));
    case 'fixture.schedule':
      final f = fixture();
      if (f == null) return;
      for (final k in const ['startsAt', 'place', 'scorerMemberId']) {
        if (p.containsKey(k)) f[k] = p[k];
      }
    case 'fixture.result':
      final f = fixture();
      if (f == null) return;
      f
        ..['status'] = 'played'
        ..['homeScore'] = p['homeScore']
        ..['awayScore'] = p['awayScore']
        // Los penales van los dos o ninguno, como en el servidor.
        ..['homePens'] = p['homePens'] != null && p['awayPens'] != null
            ? p['homePens']
            : null
        ..['awayPens'] = p['homePens'] != null && p['awayPens'] != null
            ? p['awayPens']
            : null
        ..['walkoverWinner'] = null
        ..['resultBy'] = me;
      final id = '${f['id']}';
      clearDetail(id);
      for (final raw in (p['events'] as List? ?? const [])) {
        final e = Map<String, Object?>.from(raw as Map);
        d.table('fixtureEvent')['${e['id']}'] = {
          'id': e['id'],
          'fixtureId': id,
          'teamId': e['teamId'],
          'memberId': e['memberId'],
          'kind': e['kind'],
          'assistMemberId': e['assistMemberId'],
          'minute': e['minute'],
        };
      }
      final lineups = (p['lineups'] as Map?) ?? const {};
      for (final (side, team) in [
        ('home', f['homeTeamId']),
        ('away', f['awayTeamId']),
      ]) {
        for (final m in (lineups[side] as List? ?? const [])) {
          final key = '$id:$m';
          d.table('fixtureLineup')[key] = {
            'id': key,
            'fixtureId': id,
            'teamId': team,
            'memberId': m,
          };
        }
      }
      propagate(f);
    case 'fixture.setStatus':
      final f = fixture();
      if (f == null) return;
      f
        ..['status'] = p['status']
        ..['homeScore'] = null
        ..['awayScore'] = null
        ..['homePens'] = null
        ..['awayPens'] = null
        ..['walkoverWinner'] = p['status'] == 'walkover'
            ? p['walkoverWinner']
            : null;
      clearDetail('${f['id']}');
      propagate(f);
    case 'stage.advance':
      for (final raw in (p['assignments'] as List? ?? const [])) {
        final a = raw as Map;
        final f = d.one('fixture', '${a['fixtureId']}');
        if (f == null) continue;
        if (a['homeTeamId'] != null) f['homeTeamId'] = a['homeTeamId'];
        if (a['awayTeamId'] != null) f['awayTeamId'] = a['awayTeamId'];
      }
  }
}
