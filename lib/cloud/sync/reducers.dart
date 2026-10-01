import 'club_data.dart';
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
    case 'member.unban':
      member(p['memberId'])?['status'] = 'left';
    case 'member.leave':
      if (myMemberId != null) member(myMemberId)?['status'] = 'left';
    case 'club.updateSettings':
      final club = d.club;
      if (club == null) return;
      club['settings'] = {...(club['settings'] as Map? ?? const {}), ...p};
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
  }
}

void _deactivateSeasons(ClubData d) {
  for (final s in d.all('season')) {
    s['isActive'] = false;
  }
}
