import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../domain/records.dart';
import '../../domain/stats_engine.dart';
import '../profile/player_profile_screen.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import '../widgets/player_avatar.dart';

/// Los récords del servidor, del histórico y de cada temporada.
final clubRecordsProvider = Provider.autoDispose<List<ClubRecord>>((ref) {
  final matches = ref.watch(matchesProvider).value ?? const [];
  final reports = ref.watch(reportsProvider).value ?? const [];
  final votes = ref.watch(mvpVotesProvider).value ?? const [];
  final attendance = ref.watch(attendanceProvider).value ?? const [];
  final seasons = [...ref.watch(seasonsProvider).value ?? const []]
    ..sort((a, b) => a.startDate.compareTo(b.startDate));
  return clubRecords(
    allTime: ref.watch(allTimeStatsProvider),
    bySeason: [
      for (final s in seasons)
        (
          s,
          StatsEngine(
            matches: matches,
            reports: reports,
            votes: votes,
            attendance: attendance,
            seasonId: s.id,
          ),
        ),
    ],
    dateLabel: Fmt.short,
  );
});

class RecordsScreen extends ConsumerWidget {
  const RecordsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(clubRecordsProvider);
    final users = ref.watch(usersByIdProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Récords')),
      body: records.isEmpty
          ? const EmptyState(
              icon: Icons.military_tech_outlined,
              title: 'Todavía no hay récords',
              subtitle:
                  'Salen cuando se jueguen jornadas y se confirmen goles.',
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                for (final (i, r) in records.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 1.5,
                    ),
                    child: GroupedTile(
                      index: i,
                      count: records.length,
                      onTap: () => PlayerProfileScreen.open(context, r.uid),
                      child: Row(
                        children: [
                          PlayerAvatar(user: users[r.uid], radius: 20),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r.title, style: text.labelLarge),
                                Text(
                                  users[r.uid]?.name ?? 'Jugador',
                                  style: text.titleMedium,
                                ),
                                if (r.when != null)
                                  Text(
                                    r.when!,
                                    style: text.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            '${r.value}',
                            style: text.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: scheme.tertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
