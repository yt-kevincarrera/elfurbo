import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/stats_engine.dart';
import '../profile/player_profile_screen.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import '../widgets/player_avatar.dart';

class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  RankingKind _kind = RankingKind.goals;

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(statsProvider);
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final ranking = stats.ranking(_kind);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pendingTotal = stats.stats.values.fold(
      0,
      (s, p) => s + p.pendingGoals + p.pendingAssists,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tabla'),
        actions: const [SeasonSelector()],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<RankingKind>(
                showSelectedIcon: false,
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
                segments: const [
                  ButtonSegment(value: RankingKind.goals, label: Text('Goles')),
                  ButtonSegment(
                    value: RankingKind.assists,
                    label: Text('Asist.'),
                  ),
                  ButtonSegment(value: RankingKind.mvps, label: Text('MVP')),
                  ButtonSegment(
                    value: RankingKind.contributions,
                    label: Text('G+A'),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${ref.watch(seasonFilterLabelProvider)} · ${Fmt.plural(stats.playedMatches.length, 'jornada jugada', 'jornadas jugadas')}',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (pendingTotal > 0)
                  Tooltip(
                    message:
                        'Goles y asistencias reportados que todavía no fueron confirmados. No cuentan hasta que los confirmen.',
                    child: Row(
                      children: [
                        Icon(
                          Icons.hourglass_bottom,
                          size: 14,
                          color: scheme.pending,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '$pendingTotal sin confirmar',
                          style: text.labelSmall?.copyWith(
                            color: scheme.pending,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ranking.isEmpty
                ? const EmptyState(
                    icon: Icons.leaderboard_outlined,
                    title: 'Todavía no hay estadísticas',
                    subtitle:
                        'Cuando se jueguen jornadas y se confirmen los goles, aquí sale la tabla.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 24),
                    itemCount: ranking.length,
                    itemBuilder: (context, i) {
                      final s = ranking[i];
                      final user = users[s.uid];
                      final value = switch (_kind) {
                        RankingKind.goals => s.goals,
                        RankingKind.assists => s.assists,
                        RankingKind.mvps => s.mvps,
                        RankingKind.contributions => s.contributions,
                      };
                      final perMatch = s.matchesPlayed == 0
                          ? 0.0
                          : value / s.matchesPlayed;
                      final isMe = s.uid == myUid;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 1.5,
                        ),
                        child: GroupedTile(
                          index: i,
                          count: ranking.length,
                          color: isMe
                              ? scheme.secondaryContainer
                              : scheme.surfaceContainerLow,
                          onTap: () => PlayerProfileScreen.open(context, s.uid),
                          child: Row(
                            children: [
                              _Rank(position: i + 1),
                              const SizedBox(width: 12),
                              PlayerAvatar(user: user, radius: 18),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      user?.name ?? 'Jugador',
                                      overflow: TextOverflow.ellipsis,
                                      style: text.titleMedium?.copyWith(
                                        fontWeight: isMe
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      '${Fmt.plural(s.matchesPlayed, 'jornada', 'jornadas')} · ${Fmt.decimal(perMatch)} por jornada'
                                      '${s.currentStreak >= 3 ? ' · 🔥 ${s.currentStreak}' : ''}',
                                      overflow: TextOverflow.ellipsis,
                                      style: text.bodySmall?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '$value',
                                style: text.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: i == 0 ? scheme.tertiary : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Selector de período (temporada activa / otra temporada / histórico).
class SeasonSelector extends ConsumerWidget {
  const SeasonSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seasons = ref.watch(seasonsProvider).value ?? const [];
    final filter = ref.watch(seasonFilterProvider);
    final label = ref.watch(seasonFilterLabelProvider);
    return PopupMenuButton<SeasonFilter>(
      tooltip: 'Elegir período',
      onSelected: (f) => ref.read(seasonFilterProvider.notifier).set(f),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: const ActiveSeasonFilter(),
          checked: filter is ActiveSeasonFilter,
          child: const Text('Temporada actual'),
        ),
        CheckedPopupMenuItem(
          value: const AllTimeFilter(),
          checked: filter is AllTimeFilter,
          child: const Text('Histórico total'),
        ),
        if (seasons.length > 1) const PopupMenuDivider(),
        if (seasons.length > 1)
          for (final s in seasons)
            CheckedPopupMenuItem(
              value: SpecificSeasonFilter(s.id),
              checked:
                  filter is SpecificSeasonFilter && filter.seasonId == s.id,
              child: Text(s.name),
            ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            Icon(
              Icons.expand_more,
              size: 20,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ],
        ),
      ),
    );
  }
}

/// Puesto en la tabla: el podio va en formas (el primero, dorado).
class _Rank extends StatelessWidget {
  const _Rank({required this.position});

  final int position;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final label = Text(
      '$position',
      style: text.titleMedium?.copyWith(
        fontWeight: FontWeight.w800,
        color: switch (position) {
          1 => scheme.onTertiaryContainer,
          2 || 3 => scheme.onSecondaryContainer,
          _ => scheme.onSurfaceVariant,
        },
      ),
    );
    if (position > 3) {
      return SizedBox(width: 32, child: Center(child: label));
    }
    return ShapeBadge(
      shape: position == 1 ? MaterialShapes.sunny : MaterialShapes.cookie7Sided,
      color: position == 1
          ? scheme.tertiaryContainer
          : scheme.surfaceContainerHighest,
      size: 32,
      child: label,
    );
  }
}
