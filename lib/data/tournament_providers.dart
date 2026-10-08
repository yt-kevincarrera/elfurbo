import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/tournament/player_stats.dart';
import '../domain/tournament/standings.dart';
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

// ------------------------------------------------------------- partidos

final fixturesProvider = Provider<List<Fixture>>((ref) {
  final data = ref.watch(clubDataProvider).value;
  if (data == null) return const [];
  return [
    for (final r in data.all('fixture'))
      Fixture.fromCloud(r.cast<String, dynamic>()),
  ]..sort((a, b) {
    if (a.round != b.round) return a.round.compareTo(b.round);
    if (a.stage != b.stage) return a.stage.index.compareTo(b.stage.index);
    final ga = a.groupLabel ?? '';
    final gb = b.groupLabel ?? '';
    if (ga != gb) return ga.compareTo(gb);
    return (a.slot ?? 0).compareTo(b.slot ?? 0);
  });
});

final fixtureByIdProvider = Provider.family<Fixture?, String>(
  (ref, id) => ref.watch(fixturesProvider).where((f) => f.id == id).firstOrNull,
);

final fixtureEventsProvider = Provider<List<FixtureEvent>>((ref) {
  final data = ref.watch(clubDataProvider).value;
  if (data == null) return const [];
  return [
    for (final r in data.all('fixtureEvent'))
      FixtureEvent.fromCloud(r.cast<String, dynamic>()),
  ]..sort((a, b) => (a.minute ?? 999).compareTo(b.minute ?? 999));
});

final fixtureLineupsProvider = Provider<List<FixtureLineup>>((ref) {
  final data = ref.watch(clubDataProvider).value;
  if (data == null) return const [];
  return [
    for (final r in data.all('fixtureLineup'))
      FixtureLineup.fromCloud(r.cast<String, dynamic>()),
  ];
});

final eventsOfFixtureProvider = Provider.family<List<FixtureEvent>, String>(
  (ref, id) =>
      ref.watch(fixtureEventsProvider).where((e) => e.fixtureId == id).toList(),
);

final lineupOfFixtureProvider = Provider.family<List<FixtureLineup>, String>(
  (ref, id) => ref
      .watch(fixtureLineupsProvider)
      .where((l) => l.fixtureId == id)
      .toList(),
);

/// La tabla de la liga (null) o de un grupo.
final standingsProvider = Provider.family<List<StandingRow>, String?>((
  ref,
  group,
) {
  final t = ref.watch(tournamentProvider);
  if (t == null) return const [];
  final teams = ref
      .watch(teamsProvider)
      .where((x) => x.status == TeamStatus.approved)
      .where((x) => group == null || x.groupLabel == group)
      .toList();
  final fixtures = ref
      .watch(fixturesProvider)
      .where(
        (f) => group == null
            ? f.stage == FixtureStage.league
            : f.stage == FixtureStage.group && f.groupLabel == group,
      );
  return standings(
    teams: teams,
    fixtures: fixtures,
    events: ref.watch(fixtureEventsProvider),
    rules: t.rules,
  );
});

/// Los grupos del torneo (A, B, …), de sus partidos.
final groupLabelsProvider = Provider<List<String>>((ref) {
  final labels = {
    for (final f in ref.watch(fixturesProvider))
      if (f.stage == FixtureStage.group && f.groupLabel != null) f.groupLabel!,
  };
  return labels.toList()..sort();
});

/// Quién no puede jugar cada partido (suspendidos por tarjetas).
final suspensionsProvider = Provider<Map<String, Set<String>>>((ref) {
  final t = ref.watch(tournamentProvider);
  if (t == null) return const {};
  return suspensions(
    fixtures: ref.watch(fixturesProvider),
    events: ref.watch(fixtureEventsProvider),
    rules: t.rules,
  );
});

final tournamentPlayerStatsProvider =
    Provider<Map<String, TournamentPlayerStats>>(
      (ref) => tournamentPlayerStats(
        fixtures: ref.watch(fixturesProvider),
        events: ref.watch(fixtureEventsProvider),
        lineups: ref.watch(fixtureLineupsProvider),
      ),
    );
