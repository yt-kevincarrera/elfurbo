import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/stats_engine.dart';
import '../profile/player_profile_screen.dart';
import '../widgets/common.dart';
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
                    '${ref.watch(seasonFilterLabelProvider)} · ${Fmt.plural(stats.playedMatches.length, 'partido jugado', 'partidos jugados')}',
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
                        'Cuando se jueguen partidos y se confirmen los goles, acá aparece la tabla.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
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
                      return ListTile(
                        tileColor: isMe
                            ? scheme.primaryContainer.withValues(alpha: 0.35)
                            : null,
                        onTap: () => PlayerProfileScreen.open(context, s.uid),
                        leading: SizedBox(
                          width: 56,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 22,
                                child: Text(
                                  '${i + 1}',
                                  style: text.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: i == 0
                                        ? scheme.mvpGold
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              PlayerAvatar(user: user, radius: 16),
                            ],
                          ),
                        ),
                        title: Text(
                          user?.name ?? 'Jugador',
                          style: TextStyle(
                            fontWeight: isMe ? FontWeight.bold : null,
                          ),
                        ),
                        subtitle: Text(
                          '${Fmt.plural(s.matchesPlayed, 'partido', 'partidos')} · ${Fmt.decimal(perMatch)} por partido'
                          '${s.currentStreak >= 3 ? ' · 🔥 ${s.currentStreak} seguidos' : ''}',
                        ),
                        trailing: Text(
                          '$value',
                          style: text.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
