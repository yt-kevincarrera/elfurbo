import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../domain/team_balancer.dart';
import '../../models/app_user.dart';
import '../../models/attendance.dart';
import '../../models/match_day.dart';
import '../widgets/common.dart';
import '../widgets/player_avatar.dart';

/// Armado de equipos parejos a partir de los que confirmaron asistencia.
/// Cualquiera puede proponer; solo el admin guarda en el partido.
class TeamsTab extends ConsumerStatefulWidget {
  const TeamsTab({super.key, required this.match});

  final MatchDay match;

  @override
  ConsumerState<TeamsTab> createState() => _TeamsTabState();
}

class _TeamsTabState extends ConsumerState<TeamsTab> {
  TeamSplit? _proposal;
  int _seed = 0;

  void _generate() {
    final attendance = ref.read(attendanceForMatchProvider(widget.match.id));
    final stats = ref.read(allTimeStatsProvider);
    final players = attendance.values
        .where((a) => a.status == AttendanceStatus.yes)
        .map(
          (a) => TeamCandidate(uid: a.uid, rating: stats.statsOf(a.uid).rating),
        )
        .toList();
    if (players.length < 2) {
      showMessage(
        'Hacen falta al menos 2 jugadores con asistencia confirmada.',
      );
      return;
    }
    setState(() {
      _seed++;
      _proposal = TeamBalancer.split(
        players,
        random: Random(_seed + DateTime.now().millisecondsSinceEpoch),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(usersByIdProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final stats = ref.watch(allTimeStatsProvider);
    final attendance = ref.watch(attendanceForMatchProvider(widget.match.id));
    final going = attendance.values
        .where((a) => a.status == AttendanceStatus.yes)
        .length;
    final saved = widget.match.hasTeams;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    TeamSplit? shown = _proposal;
    if (shown == null && saved) {
      shown = TeamSplit(
        teamA: widget.match.teamA
            .map((u) => TeamCandidate(uid: u, rating: stats.statsOf(u).rating))
            .toList(),
        teamB: widget.match.teamB
            .map((u) => TeamCandidate(uid: u, rating: stats.statsOf(u).rating))
            .toList(),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            saved && _proposal == null
                ? 'Equipos guardados por el admin.'
                : 'Se reparten los $going que marcaron que van, usando goles, asistencias y MVPs históricos para que queden parejos.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: widget.match.isCancelled ? null : _generate,
                icon: const Icon(Icons.shuffle),
                label: Text(
                  _proposal == null ? 'Armar equipos' : 'Mezclar de nuevo',
                ),
              ),
              if (isAdmin && _proposal != null)
                FilledButton.icon(
                  onPressed: () {
                    fireAndForget(
                      ref
                          .read(repoProvider)
                          .saveTeams(
                            widget.match.id,
                            _proposal!.uidsA,
                            _proposal!.uidsB,
                          ),
                      success: 'Equipos guardados',
                    );
                    setState(() => _proposal = null);
                  },
                  icon: const Icon(Icons.save),
                  label: const Text('Guardar'),
                ),
              if (isAdmin && saved && _proposal == null)
                OutlinedButton.icon(
                  onPressed: () => fireAndForget(
                    ref.read(repoProvider).clearTeams(widget.match.id),
                    success: 'Equipos borrados',
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Borrar'),
                ),
              if (_proposal != null && saved)
                TextButton(
                  onPressed: () => setState(() => _proposal = null),
                  child: const Text('Ver guardados'),
                ),
            ],
          ),
        ),
        if (shown == null)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: EmptyState(
              icon: Icons.groups_outlined,
              title: 'Todavía no hay equipos',
              subtitle:
                  'Cuando el grupo confirme asistencia, armalos con un toque.',
            ),
          )
        else ...[
          _TeamCard(
            title: 'Equipo A',
            color: scheme.primary,
            players: shown.teamA,
            users: users,
            rating: shown.ratingA,
          ),
          _TeamCard(
            title: 'Equipo B',
            color: scheme.tertiary,
            players: shown.teamB,
            users: users,
            rating: shown.ratingB,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              'Diferencia de valoración: ${Fmt.decimal(shown.difference)}. '
              'La valoración es (goles + 0,7·asistencias + 1,5·MVP) por partido jugado; los nuevos arrancan en el promedio.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }
}

class _TeamCard extends StatelessWidget {
  const _TeamCard({
    required this.title,
    required this.color,
    required this.players,
    required this.users,
    required this.rating,
  });

  final String title;
  final Color color;
  final List<TeamCandidate> players;
  final Map<String, AppUser> users;
  final double rating;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$title (${players.length})',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  '★ ${Fmt.decimal(rating)}',
                  style: text.labelLarge?.copyWith(color: color),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final p in players)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: PlayerAvatar(user: users[p.uid], radius: 16),
                title: Text(users[p.uid]?.name ?? 'Jugador'),
                trailing: Text(Fmt.decimal(p.rating), style: text.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}
