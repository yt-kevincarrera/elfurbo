import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../data/providers.dart';
import '../../models/app_user.dart';
import '../../models/attendance.dart';
import '../../models/match_day.dart';
import '../widgets/common.dart';
import '../widgets/player_avatar.dart';

class AttendanceTab extends ConsumerWidget {
  const AttendanceTab({super.key, required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attendance = ref.watch(attendanceForMatchProvider(match.id));
    final users = ref.watch(activeUsersProvider);
    final myUid = ref.watch(myUidProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final mine = attendance[myUid]?.status;
    final played = match.isPlayed(DateTime.now());

    List<AppUser> withStatus(AttendanceStatus? s) =>
        users.where((u) => attendance[u.uid]?.status == s).toList();
    final yes = withStatus(AttendanceStatus.yes);
    final maybe = withStatus(AttendanceStatus.maybe);
    final no = withStatus(AttendanceStatus.no);
    final unanswered = withStatus(null);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  played ? '¿Jugaste este partido?' : '¿Vas a ir?',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  played
                      ? 'Marca "Jugué" para poder cargar tus goles, confirmar a otros y votar MVP.'
                      : 'Con esto el grupo sabe si llegan a completar equipos.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AttendanceStatus>(
                    emptySelectionAllowed: true,
                    showSelectedIcon: false,
                    selected: {if (mine != null) mine},
                    onSelectionChanged: match.isCancelled
                        ? null
                        : (sel) {
                            if (sel.isEmpty) return;
                            fireAndForget(
                              ref
                                  .read(repoProvider)
                                  .setAttendance(match.id, myUid, sel.first),
                            );
                          },
                    segments: [
                      ButtonSegment(
                        value: AttendanceStatus.yes,
                        label: Text(played ? 'Jugué' : 'Voy'),
                        icon: const Icon(Icons.check),
                      ),
                      const ButtonSegment(
                        value: AttendanceStatus.maybe,
                        label: Text('Quizás'),
                        icon: Icon(Icons.question_mark),
                      ),
                      ButtonSegment(
                        value: AttendanceStatus.no,
                        label: Text(played ? 'No fui' : 'No voy'),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        _Group(
          title: played ? 'Jugaron' : 'Van',
          users: yes,
          icon: Icons.check_circle,
          color: Colors.green,
          match: match,
          canEdit: isAdmin,
        ),
        _Group(
          title: 'Quizás',
          users: maybe,
          icon: Icons.help,
          color: Colors.amber.shade700,
          match: match,
          canEdit: isAdmin,
        ),
        _Group(
          title: played ? 'No fueron' : 'No van',
          users: no,
          icon: Icons.cancel,
          color: Colors.red,
          match: match,
          canEdit: isAdmin,
        ),
        _Group(
          title: 'Sin responder',
          users: unanswered,
          icon: Icons.radio_button_unchecked,
          color: Colors.grey,
          match: match,
          canEdit: isAdmin,
        ),
      ],
    );
  }
}

class _Group extends ConsumerWidget {
  const _Group({
    required this.title,
    required this.users,
    required this.icon,
    required this.color,
    required this.match,
    required this.canEdit,
  });

  final String title;
  final List<AppUser> users;
  final IconData icon;
  final Color color;
  final MatchDay match;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (users.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle('$title (${users.length})'),
        for (final u in users)
          ListTile(
            dense: true,
            leading: PlayerAvatar(user: u, radius: 18),
            title: Text(u.name),
            trailing: Icon(icon, color: color, size: 20),
            onLongPress: canEdit ? () => _adminSet(context, ref, u) : null,
          ),
        if (canEdit)
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Text(
              'Mantén presionado un jugador para cambiarle la asistencia.',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _adminSet(BuildContext context, WidgetRef ref, AppUser u) async {
    final status = await showModalBottomSheet<AttendanceStatus>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              'Asistencia de ${u.name}',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: const Text('Sí / Jugó'),
            onTap: () => Navigator.pop(ctx, AttendanceStatus.yes),
          ),
          ListTile(
            leading: const Icon(Icons.help, color: Colors.amber),
            title: const Text('Quizás'),
            onTap: () => Navigator.pop(ctx, AttendanceStatus.maybe),
          ),
          ListTile(
            leading: const Icon(Icons.cancel, color: Colors.red),
            title: const Text('No'),
            onTap: () => Navigator.pop(ctx, AttendanceStatus.no),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
    if (status == null) return;
    fireAndForget(
      ref.read(repoProvider).setAttendance(match.id, u.uid, status),
      success: 'Asistencia de ${u.name} actualizada',
    );
  }
}
