import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../data/tournament_providers.dart';
import '../../domain/tournament/awards.dart';
import '../../models/tournament.dart';
import '../profile/global_stats.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';

/// Terminar el torneo (organizadores) o, si ya terminó, reabrirlo.
class FinishSection extends ConsumerWidget {
  const FinishSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tournamentProvider);
    final readOnly = ref.watch(clubReadOnlyProvider);
    if (t == null || readOnly) return const SizedBox.shrink();
    if (t.status == TournamentStatus.finished) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: OutlinedButton.icon(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('¿Reabrir el torneo?'),
                content: const Text(
                  'Vuelve a estar en juego para corregir algo. Los premios se quitan '
                  'y se dan otra vez al terminarlo.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancelar'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Reabrir'),
                  ),
                ],
              ),
            );
            if (ok != true) return;
            fireAndForget(
              ref.read(repoProvider).reopenTournament(),
              success: 'Listo, el torneo está en juego otra vez',
            );
          },
          icon: const Icon(Icons.lock_open),
          label: const Text('Reabrir el torneo'),
        ),
      );
    }
    if (t.status != TournamentStatus.inProgress) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: FilledButton.icon(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => const _FinishSheet(),
        ),
        icon: const Icon(Icons.emoji_events),
        label: const Text('Terminar el torneo'),
      ),
    );
  }
}

class _FinishSheet extends ConsumerStatefulWidget {
  const _FinishSheet();

  @override
  ConsumerState<_FinishSheet> createState() => _FinishSheetState();
}

class _FinishSheetState extends ConsumerState<_FinishSheet> {
  late List<AwardProposal> _awards;

  @override
  void initState() {
    super.initState();
    _awards = proposeAwards(
      tournament: ref.read(tournamentProvider)!,
      teams: ref.read(teamsProvider),
      fixtures: ref.read(fixturesProvider),
      events: ref.read(fixtureEventsProvider),
      lineups: ref.read(fixtureLineupsProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    final teams = {for (final t in ref.watch(teamsProvider)) t.id: t};
    final users = ref.watch(usersByIdProvider);
    final rosters = ref.watch(rostersProvider);
    final players = [
      for (final r in rosters.values)
        for (final p in r) p.memberId,
    ];
    final pending = ref
        .watch(fixturesProvider)
        .where((f) => !f.decided && f.status != FixtureStatus.cancelled);
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text('Terminar el torneo', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            pending.isEmpty
                ? 'Estos son los premios. Puedes cambiar el mejor jugador.'
                : 'Quedan ${Fmt.plural(pending.length, 'partido', 'partidos')} sin resultado. '
                      'Si terminas ahora, no cuentan.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 8),
          for (final (i, a) in _awards.indexed)
            if (a.kind == 'best_player')
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: DropdownButtonFormField<String>(
                  initialValue: a.memberId,
                  decoration: const InputDecoration(
                    labelText: '⭐ Mejor jugador',
                  ),
                  items: [
                    for (final m in players)
                      DropdownMenuItem(
                        value: m,
                        child: Text(users[m]?.name ?? 'Jugador'),
                      ),
                  ],
                  onChanged: (v) =>
                      setState(() => _awards[i] = a.copyWith(memberId: v)),
                ),
              )
            else
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Text(
                  TrophyTile.labels[a.kind]?.$1 ?? '🏅',
                  style: const TextStyle(fontSize: 26),
                ),
                title: Text(TrophyTile.labels[a.kind]?.$2 ?? a.kind),
                subtitle: Text(
                  [
                    if (a.teamId != null) teams[a.teamId]?.name ?? '',
                    if (a.memberId != null) users[a.memberId]?.name ?? '',
                    if (a.value != null) '${a.value}',
                  ].join(' · '),
                ),
              ),
          if (_awards.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Todavía no hay resultados para dar premios.'),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              fireAndForget(
                ref.read(repoProvider).finishTournament([
                  for (final a in _awards) a.toJson(),
                ]),
                success: '¡Torneo terminado! Felicidades al campeón.',
              );
            },
            child: const Text('Terminar y dar los premios'),
          ),
        ],
      ),
    );
  }
}

/// Los premios del torneo terminado (arriba de la tabla).
class AwardsBanner extends ConsumerWidget {
  const AwardsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final awards = ref.watch(awardsProvider);
    if (awards.isEmpty) return const SizedBox.shrink();
    final teams = {for (final t in ref.watch(teamsProvider)) t.id: t};
    final users = ref.watch(usersByIdProvider);
    const order = [
      'champion',
      'runner_up',
      'third',
      'top_scorer',
      'top_assists',
      'best_player',
      'fair_play',
    ];
    final sorted = [...awards]
      ..sort((a, b) => order.indexOf(a.kind).compareTo(order.indexOf(b.kind)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Premios'),
        GroupedSection(
          children: [
            for (final a in sorted)
              ListTile(
                dense: true,
                leading: Text(
                  TrophyTile.labels[a.kind]?.$1 ?? '🏅',
                  style: const TextStyle(fontSize: 24),
                ),
                title: Text(TrophyTile.labels[a.kind]?.$2 ?? a.kind),
                subtitle: Text(
                  [
                    if (a.teamId != null) teams[a.teamId]?.name ?? '',
                    if (a.memberId != null) users[a.memberId]?.name ?? '',
                    if (a.value != null && a.kind == 'top_scorer')
                      Fmt.goals(a.value!),
                    if (a.value != null && a.kind == 'top_assists')
                      Fmt.assists(a.value!),
                  ].join(' · '),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
