import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/stats_engine.dart';
import '../../models/attendance.dart';
import '../../models/match_day.dart';
import '../widgets/common.dart';
import '../widgets/player_avatar.dart';

class MvpTab extends ConsumerWidget {
  const MvpTab({super.key, required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!match.isPlayed(DateTime.now())) {
      return EmptyState(
        icon: Icons.emoji_events_outlined,
        title: match.isCancelled
            ? 'Partido cancelado'
            : 'La votación abre después del partido',
      );
    }
    final attendance = ref.watch(attendanceForMatchProvider(match.id));
    final votes = ref.watch(votesForMatchProvider(match.id));
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final iPlayed = attendance[myUid]?.status == AttendanceStatus.yes;
    final myVote = votes.where((v) => v.voterUid == myUid).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final candidates =
        attendance.values
            .where((a) => a.status == AttendanceStatus.yes && a.uid != myUid)
            .map((a) => users[a.uid])
            .nonNulls
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );

    final counts = <String, int>{};
    for (final v in votes) {
      counts[v.votedFor] = (counts[v.votedFor] ?? 0) + 1;
    }
    final tally = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final winners = StatsEngine.mvpWinners(votes).toSet();

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (tally.isNotEmpty) ...[
          const SectionTitle('Votación'),
          for (final e in tally)
            ListTile(
              leading: PlayerAvatar(user: users[e.key], radius: 18),
              title: Text(users[e.key]?.name ?? 'Jugador'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (winners.contains(e.key))
                    Icon(Icons.emoji_events, color: scheme.mvpGold),
                  const SizedBox(width: 8),
                  Text(
                    '${e.value}',
                    style: text.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '${votes.length} ${votes.length == 1 ? 'voto' : 'votos'} · si hay empate, todos los empatados suman MVP.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
        const SectionTitle('Tu voto'),
        if (!iPlayed)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'Para votar tenés que marcar "Jugué" en la pestaña Asistencia.',
              style: text.bodyMedium?.copyWith(color: scheme.pending),
            ),
          )
        else if (candidates.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'Nadie más marcó que jugó todavía.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else ...[
          RadioGroup<String>(
            groupValue: myVote?.votedFor,
            onChanged: (uid) {
              if (match.isCancelled || uid == null) return;
              final name = users[uid]?.name ?? 'Jugador';
              fireAndForget(
                ref
                    .read(repoProvider)
                    .voteMvp(matchId: match.id, voterUid: myUid, votedFor: uid),
                success: 'Votaste a $name',
              );
            },
            child: Column(
              children: [
                for (final u in candidates)
                  RadioListTile<String>(
                    value: u.uid,
                    title: Text(u.name),
                    secondary: PlayerAvatar(user: u, radius: 18),
                  ),
              ],
            ),
          ),
          if (myVote != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextButton(
                  onPressed: () => fireAndForget(
                    ref.read(repoProvider).removeMvpVote(match.id, myUid),
                    success: 'Voto retirado',
                  ),
                  child: const Text('Quitar mi voto'),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
