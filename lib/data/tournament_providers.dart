import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tournament.dart';
import 'providers.dart';

// Lo del torneo elegido en el selector, de su vista local (funciona sin señal).

/// El torneo (null si el servidor elegido no es un torneo o no llegó todavía).
final tournamentProvider = Provider<Tournament?>((ref) {
  final data = ref.watch(clubDataProvider).value;
  final row = data?.one('tournament', data.clubId);
  return row == null ? null : Tournament.fromCloud(row.cast<String, dynamic>());
});

/// Los equipos: aprobados primero, después pendientes; los retirados al final.
final teamsProvider = Provider<List<Team>>((ref) {
  final data = ref.watch(clubDataProvider).value;
  if (data == null) return const [];
  final teams = [
    for (final r in data.all('team')) Team.fromCloud(r.cast<String, dynamic>()),
  ];
  int rank(Team t) => switch (t.status) {
    TeamStatus.approved => 0,
    TeamStatus.pending => 1,
    TeamStatus.withdrawn => 2,
  };
  return teams..sort(
    (a, b) => rank(a) != rank(b)
        ? rank(a).compareTo(rank(b))
        : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );
});

final teamByIdProvider = Provider.family<Team?, String>(
  (ref, id) => ref.watch(teamsProvider).where((t) => t.id == id).firstOrNull,
);

/// Las plantillas activas, por equipo.
final rostersProvider = Provider<Map<String, List<TeamPlayer>>>((ref) {
  final data = ref.watch(clubDataProvider).value;
  if (data == null) return const {};
  final out = <String, List<TeamPlayer>>{};
  for (final r in data.all('teamPlayer')) {
    final tp = TeamPlayer.fromCloud(r.cast<String, dynamic>());
    if (tp.active) out.putIfAbsent(tp.teamId, () => []).add(tp);
  }
  return out;
});

final rosterProvider = Provider.family<List<TeamPlayer>, String>(
  (ref, teamId) => ref.watch(rostersProvider)[teamId] ?? const [],
);

/// El equipo (activo) de un miembro en este torneo.
final teamOfMemberProvider = Provider.family<Team?, String>((ref, memberId) {
  for (final e in ref.watch(rostersProvider).entries) {
    if (e.value.any((p) => p.memberId == memberId)) {
      final team = ref.watch(teamByIdProvider(e.key));
      if (team != null && team.status != TeamStatus.withdrawn) return team;
    }
  }
  return null;
});

/// Mi equipo en este torneo.
final myTeamProvider = Provider<Team?>(
  (ref) => ref.watch(teamOfMemberProvider(ref.watch(myUidProvider))),
);
