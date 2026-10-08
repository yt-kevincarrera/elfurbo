import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/sync/command.dart';
import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../data/tournament_providers.dart';
import '../../domain/tournament/generators.dart';
import '../../models/tournament.dart';
import '../widgets/common.dart';

/// El calendario en el Admin del torneo: generarlo con los equipos aprobados
/// (según el formato), borrarlo mientras no tenga resultados y, en grupos con
/// copa, cerrar los grupos para armar el cuadro.
class CalendarAdminSection extends ConsumerWidget {
  const CalendarAdminSection({super.key});

  /// Los equipos aprobados, por cabeza de serie y después por nombre.
  static List<Team> seeded(List<Team> teams) =>
      teams.where((t) => t.status == TeamStatus.approved).toList()
        ..sort((a, b) {
          if (a.seed != b.seed) {
            if (a.seed == null) return 1;
            if (b.seed == null) return -1;
            return a.seed!.compareTo(b.seed!);
          }
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tournamentProvider);
    final fixtures = ref.watch(fixturesProvider);
    final teams = seeded(ref.watch(teamsProvider));
    final readOnly = ref.watch(clubReadOnlyProvider);
    if (t == null || t.status == TournamentStatus.finished) {
      return const SizedBox.shrink();
    }
    final text = Theme.of(context).textTheme;
    final repo = ref.read(repoProvider);
    final decided = fixtures.any((f) => f.decided);
    final groupFixtures = fixtures.where((f) => f.stage == FixtureStage.group);
    final pendingAssignments = _qualifiers(ref, fixtures);
    final canCloseGroups =
        groupFixtures.isNotEmpty &&
        groupFixtures.every(
          (f) => f.decided || f.status == FixtureStatus.cancelled,
        ) &&
        pendingAssignments.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Calendario'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            fixtures.isEmpty
                ? 'Con ${Fmt.plural(teams.length, 'equipo aprobado', 'equipos aprobados')}. '
                      'Se reparte una ronda por semana desde el día de inicio; después '
                      'puedes mover cada partido.'
                : '${Fmt.plural(fixtures.length, 'partido', 'partidos')}, '
                      '${fixtures.where((f) => f.decided).length} con resultado.',
            style: text.bodyMedium,
          ),
        ),
        if (!readOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (fixtures.isEmpty)
                  FilledButton.icon(
                    onPressed: teams.length < 2
                        ? null
                        : () => _generate(context, ref, t, teams),
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Generar calendario'),
                  ),
                if (fixtures.isNotEmpty && !decided)
                  OutlinedButton(
                    onPressed: () => _clear(context, ref, t),
                    child: const Text('Borrar calendario'),
                  ),
                if (canCloseGroups)
                  FilledButton.icon(
                    onPressed: () => fireAndForget(
                      repo.advanceStage(pendingAssignments),
                      success: '¡Grupos cerrados! Ya está el cuadro.',
                    ),
                    icon: const Icon(Icons.account_tree_outlined),
                    label: const Text('Cerrar grupos'),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Los equipos de cada partido del cuadro que salen de un puesto de grupo,
  /// con las tablas de ahora.
  static List<({String fixtureId, String? homeTeamId, String? awayTeamId})>
  _qualifiers(WidgetRef ref, List<Fixture> fixtures) {
    final out =
        <({String fixtureId, String? homeTeamId, String? awayTeamId})>[];
    final tables = <String, List<String>>{};
    List<String> table(String g) => tables.putIfAbsent(
      g,
      () => [for (final r in ref.read(standingsProvider(g))) r.teamId],
    );
    String? team(TeamSource? s) {
      if (s?.group == null || s?.pos == null) return null;
      final t = table(s!.group!);
      return s.pos! <= t.length ? t[s.pos! - 1] : null;
    }

    for (final f in fixtures.where((f) => f.isKnockout && !f.decided)) {
      final home = f.homeTeamId == null ? team(f.homeSource) : null;
      final away = f.awayTeamId == null ? team(f.awaySource) : null;
      if (home != null || away != null) {
        out.add((fixtureId: f.id, homeTeamId: home, awayTeamId: away));
      }
    }
    return out;
  }

  Future<void> _generate(
    BuildContext context,
    WidgetRef ref,
    Tournament t,
    List<Team> teams,
  ) async {
    final ids = [for (final x in teams) x.id];
    final r = t.rules;
    final List<FixtureDraft> group;
    final List<FixtureDraft> knockout;
    Map<String, String>? groupOf;
    switch (t.format) {
      case TournamentFormat.league:
        group = leagueFixtures(ids, newId: uuidV4, legs: r.legs);
        knockout = const [];
      case TournamentFormat.cup:
        group = const [];
        knockout = cupFixtures(
          [for (final id in ids) Entrant.team(id)],
          newId: uuidV4,
          thirdPlace: r.thirdPlace,
        );
      case TournamentFormat.groupsCup:
        final g = groupsCupFixtures(
          ids,
          newId: uuidV4,
          groups: r.groups.clamp(1, ids.length ~/ 2),
          advance: r.advancePerGroup,
          legs: r.legs,
          thirdPlace: r.thirdPlace,
        );
        group = g.fixtures.where((f) => f.stage == FixtureStage.group).toList();
        knockout = g.fixtures
            .where((f) => f.stage != FixtureStage.group)
            .toList();
        groupOf = {
          for (final e in g.groups.entries)
            for (final team in e.value) team: e.key,
        };
    }
    if (t.startsOn != null) {
      scheduleWeekly([...group, ...knockout], t.startsOn!);
    }
    final rounds = {
      for (final f in [...group, ...knockout]) f.round,
    }.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Generar el calendario?'),
        content: Text(
          '${t.format.label}: ${group.length + knockout.length} partidos en '
          '${Fmt.plural(rounds, 'ronda', 'rondas')}'
          '${t.startsOn == null ? ', sin fechas (pon el día de inicio para repartirlas)' : ''}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Generar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = ref.read(repoProvider);
    try {
      if (group.isNotEmpty) {
        await repo.generateFixtures(
          t.format == TournamentFormat.league ? 'league' : 'group',
          [for (final f in group) f.toJson()],
          groups: groupOf,
        );
      }
      if (knockout.isNotEmpty) {
        await repo.generateFixtures('knockout', [
          for (final f in knockout) f.toJson(),
        ]);
      }
      showMessage('¡Calendario listo!');
    } catch (e) {
      showError(e);
    }
  }

  Future<void> _clear(BuildContext context, WidgetRef ref, Tournament t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar el calendario?'),
        content: const Text(
          'Se borran todos los partidos (todavía sin resultados).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = ref.read(repoProvider);
    final stages = {
      for (final f in ref.read(fixturesProvider))
        switch (f.stage) {
          FixtureStage.league => 'league',
          FixtureStage.group => 'group',
          _ => 'knockout',
        },
    };
    for (final s in stages) {
      fireAndForget(repo.clearFixtures(s));
    }
    showMessage('Listo, calendario borrado');
  }
}
