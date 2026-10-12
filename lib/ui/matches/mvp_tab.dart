import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/stats_engine.dart';
import '../../models/app_user.dart';
import '../../models/match_day.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
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
            ? 'Jornada cancelada'
            : 'La votación abre cuando termine la jornada',
      );
    }
    final votes = ref.watch(votesForMatchProvider(match.id));
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final closed = ref.watch(matchClosedProvider(match.id));
    final iPlayed = ref.watch(iAmPresentProvider(match.id));
    final present = ref.watch(presentUidsProvider(match.id));
    final isAdmin = ref.watch(isAdminProvider);
    final canPick = ref.watch(canPickMvpProvider(match.id));
    final myVote = votes.where((v) => v.voterUid == myUid).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final note = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    final candidates =
        present
            .where((uid) => uid != myUid)
            .map((uid) => users[uid])
            .nonNulls
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    final pickable = canPick
        ? ref.watch(mvpPickCandidatesProvider(match.id))
        : const <AppUser>[];

    final counts = <String, int>{};
    for (final v in votes) {
      counts[v.votedFor] = (counts[v.votedFor] ?? 0) + 1;
    }
    final tally = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final reports = ref.watch(reportsForMatchProvider(match.id));
    final winners = StatsEngine.mvpWinners(
      votes,
      confirmedReports: {
        for (final r in reports)
          if (r.isConfirmed) r.uid: r,
      },
      pick: match.mvpPick,
    ).toSet();
    // Sin votos, el MVP lo eligió un admin a dedo (los votos ganan siempre).
    final picked = votes.isEmpty ? match.mvpPick : null;

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
              '${votes.length} ${votes.length == 1 ? 'voto' : 'votos'} · si hay empate, desempata por goles y asistencias confirmados del día; si sigue igual, comparten.',
              style: note,
            ),
          ),
        ],
        if (picked != null) ...[
          const SectionTitle('MVP'),
          ListTile(
            leading: PlayerAvatar(user: users[picked], radius: 18),
            title: Text(users[picked]?.name ?? 'Jugador'),
            trailing: Icon(Icons.emoji_events, color: scheme.mvpGold),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(_pickNote(picked, match.mvpPickBy, users), style: note),
          ),
        ],
        if (canPick) ...[
          SectionTitle(picked == null ? 'Nadie votó' : 'Cambiar el MVP'),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Como nadie votó, el MVP lo eliges tú.', style: note),
          ),
          // Los que jugaron o pusieron goles, y siempre yo.
          _PlayerList(
            players: pickable,
            selected: picked,
            enabled: true,
            onPick: (u) => fireAndForget(
              ref.read(repoProvider).pickMvp(match.id, u.uid),
              success: u.uid == myUid
                  ? 'Listo, eres el MVP'
                  : 'Listo, ${u.name} es el MVP',
            ),
          ),
          if (picked != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextButton(
                  onPressed: () => fireAndForget(
                    ref.read(repoProvider).pickMvp(match.id, null),
                    success: 'MVP quitado',
                  ),
                  child: const Text('Quitar'),
                ),
              ),
            ),
        ] else ...[
          const SectionTitle('Tu voto'),
          if (!iPlayed)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Para votar tienes que marcar "Jugué" en la pestaña Asistencia.',
                style: text.bodyMedium?.copyWith(color: scheme.pending),
              ),
            )
          else if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Nadie más ha marcado que jugó.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else ...[
            _PlayerList(
              players: candidates,
              selected: myVote?.votedFor,
              enabled: !closed,
              onPick: (u) => fireAndForget(
                ref.read(repoProvider).castVote(match.id, u.uid),
                success: 'Votaste a ${u.name}',
              ),
            ),
            if (myVote != null && !closed)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextButton(
                    onPressed: () => fireAndForget(
                      ref.read(repoProvider).clearVote(match.id),
                      success: 'Voto retirado',
                    ),
                    child: const Text('Quitar mi voto'),
                  ),
                ),
              ),
          ],
          // Al admin se le avisa de que, si nadie vota, le toca elegir.
          if (isAdmin && votes.isEmpty && !closed)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                'Si cierra sin votos, el MVP lo eliges tú.',
                style: note,
              ),
            ),
        ],
      ],
    );
  }

  /// Quién eligió el MVP a dedo. Si se eligió a sí mismo, se dice claro.
  static String _pickNote(
    String picked,
    String? by,
    Map<String, AppUser> users,
  ) {
    if (by == null) return 'Nadie votó: lo eligió un admin.';
    final name = users[by]?.name ?? 'un admin';
    return by == picked
        ? 'Nadie votó: $name se eligió a sí mismo.'
        : 'Nadie votó: lo eligió $name.';
  }
}

/// Lista de jugadores para elegir uno (votar o elegir el MVP a dedo).
class _PlayerList extends StatelessWidget {
  const _PlayerList({
    required this.players,
    required this.selected,
    required this.enabled,
    required this.onPick,
  });

  final List<AppUser> players;
  final String? selected;
  final bool enabled;
  final void Function(AppUser u) onPick;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<String>(
      groupValue: selected,
      onChanged: (uid) {
        if (!enabled || uid == null) return;
        final u = players.where((p) => p.uid == uid).firstOrNull;
        if (u != null) onPick(u);
      },
      child: Column(
        children: [
          for (final (i, u) in players.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 1.5,
              ),
              child: GroupedTile(
                index: i,
                count: players.length,
                color: selected == u.uid
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : null,
                onTap: !enabled || selected == u.uid ? null : () => onPick(u),
                padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                child: Row(
                  children: [
                    PlayerAvatar(user: u, radius: 18),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        u.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Radio<String>(value: u.uid),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
