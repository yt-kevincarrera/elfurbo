import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../data/providers.dart';
import '../../models/app_user.dart';
import '../../models/attendance.dart';
import '../../models/match_day.dart';
import '../widgets/common.dart';
import '../widgets/player_avatar.dart';

/// Asistencia de una jornada.
///
/// Antes de jugarse: intención (Voy / Quizás / No voy). Después: presencia
/// real (Jugué / No fui), que es lo único que cuenta para estadísticas. El
/// admin puede pasar lista.
class AttendanceTab extends ConsumerWidget {
  const AttendanceTab({super.key, required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final played = match.isPlayed(DateTime.now());
    return played ? _PresenceView(match: match) : _IntentionView(match: match);
  }
}

// ----------------------------------------------------------------- intención

class _IntentionView extends ConsumerWidget {
  const _IntentionView({required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attendance = ref.watch(attendanceForMatchProvider(match.id));
    final users = ref.watch(activeUsersProvider);
    final myUid = ref.watch(myUidProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final closed = ref.watch(matchClosedProvider(match.id));
    final mine = attendance[myUid]?.status;

    List<AppUser> withStatus(AttendanceStatus? s) =>
        users.where((u) => attendance[u.uid]?.status == s).toList();

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
                  '¿Vas a ir?',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Con esto el grupo sabe si llegan a completar equipos. Cuando termine la jornada confirmas si jugaste.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AttendanceStatus>(
                    emptySelectionAllowed: true,
                    showSelectedIcon: false,
                    selected: {if (mine != null) mine},
                    onSelectionChanged: closed
                        ? null
                        : (sel) {
                            if (sel.isEmpty) return;
                            fireAndForget(
                              ref
                                  .read(repoProvider)
                                  .setAttendance(match.id, myUid, sel.first),
                            );
                          },
                    segments: const [
                      ButtonSegment(
                        value: AttendanceStatus.yes,
                        label: Text('Voy'),
                        icon: Icon(Icons.check),
                      ),
                      ButtonSegment(
                        value: AttendanceStatus.maybe,
                        label: Text('Quizás'),
                        icon: Icon(Icons.question_mark),
                      ),
                      ButtonSegment(
                        value: AttendanceStatus.no,
                        label: Text('No voy'),
                        icon: Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        _Group(
          title: 'Van',
          users: withStatus(AttendanceStatus.yes),
          icon: Icons.check_circle,
          color: Colors.green,
          onLongPress: isAdmin && !closed
              ? (u) => _adminSetIntention(context, ref, u)
              : null,
        ),
        _Group(
          title: 'Quizás',
          users: withStatus(AttendanceStatus.maybe),
          icon: Icons.help,
          color: Colors.amber.shade700,
          onLongPress: isAdmin && !closed
              ? (u) => _adminSetIntention(context, ref, u)
              : null,
        ),
        _Group(
          title: 'No van',
          users: withStatus(AttendanceStatus.no),
          icon: Icons.cancel,
          color: Colors.red,
          onLongPress: isAdmin && !closed
              ? (u) => _adminSetIntention(context, ref, u)
              : null,
        ),
        _Group(
          title: 'Sin responder',
          users: withStatus(null),
          icon: Icons.radio_button_unchecked,
          color: Colors.grey,
          onLongPress: isAdmin && !closed
              ? (u) => _adminSetIntention(context, ref, u)
              : null,
        ),
        if (isAdmin && !closed)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              'Mantén presionado un jugador para cambiarle la respuesta.',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _adminSetIntention(
    BuildContext context,
    WidgetRef ref,
    AppUser u,
  ) async {
    final status = await showModalBottomSheet<AttendanceStatus>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              'Respuesta de ${u.name}',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: const Text('Va'),
            onTap: () => Navigator.pop(ctx, AttendanceStatus.yes),
          ),
          ListTile(
            leading: const Icon(Icons.help, color: Colors.amber),
            title: const Text('Quizás'),
            onTap: () => Navigator.pop(ctx, AttendanceStatus.maybe),
          ),
          ListTile(
            leading: const Icon(Icons.cancel, color: Colors.red),
            title: const Text('No va'),
            onTap: () => Navigator.pop(ctx, AttendanceStatus.no),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
    if (status == null) return;
    fireAndForget(
      ref.read(repoProvider).setAttendance(match.id, u.uid, status),
      success: 'Respuesta de ${u.name} actualizada',
    );
  }
}

// ----------------------------------------------------------------- presencia

class _PresenceView extends ConsumerWidget {
  const _PresenceView({required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attendance = ref.watch(attendanceForMatchProvider(match.id));
    final users = ref.watch(activeUsersProvider);
    final myUid = ref.watch(myUidProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final closed = ref.watch(matchClosedProvider(match.id));
    final mine = attendance[myUid];
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final present = users.where((u) => attendance[u.uid]?.isPresent ?? false);
    final absent = users.where((u) => attendance[u.uid]?.isAbsent ?? false);
    final unknown = users.where(
      (u) => attendance[u.uid]?.presenceUnknown ?? true,
    );

    String intentionOf(AppUser u) => switch (attendance[u.uid]?.status) {
      AttendanceStatus.yes => 'dijo que iba',
      AttendanceStatus.no => 'dijo que no iba',
      AttendanceStatus.maybe when attendance[u.uid] != null => 'dijo quizás',
      _ => 'no respondió',
    };

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('¿Jugaste esta jornada?', style: text.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Solo lo que confirmes aquí cuenta como jornada jugada. Cargar goles también te marca presente.',
                  style: text.bodySmall,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<bool>(
                    emptySelectionAllowed: true,
                    showSelectedIcon: false,
                    selected: {if (mine?.played != null) mine!.played!},
                    onSelectionChanged: closed
                        ? null
                        : (sel) {
                            if (sel.isEmpty) return;
                            fireAndForget(
                              ref
                                  .read(repoProvider)
                                  .setPresence(
                                    match.id,
                                    myUid,
                                    sel.first,
                                    setBy: myUid,
                                  ),
                            );
                          },
                    segments: const [
                      ButtonSegment(
                        value: true,
                        label: Text('Jugué'),
                        icon: Icon(Icons.check),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text('No fui'),
                        icon: Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                if (isAdmin) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      onPressed: closed
                          ? null
                          : () => _passList(context, ref, users, attendance),
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Pasar lista'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        _Group(
          title: 'Jugaron',
          users: present.toList(),
          icon: Icons.check_circle,
          color: Colors.green,
          onLongPress: isAdmin && !closed
              ? (u) => _adminSetPresence(context, ref, u)
              : null,
        ),
        _Group(
          title: 'No fueron',
          users: absent.toList(),
          icon: Icons.cancel,
          color: Colors.red,
          onLongPress: isAdmin && !closed
              ? (u) => _adminSetPresence(context, ref, u)
              : null,
        ),
        _Group(
          title: 'Sin confirmar',
          users: unknown.toList(),
          icon: Icons.radio_button_unchecked,
          color: Colors.grey,
          subtitleOf: intentionOf,
          onLongPress: isAdmin && !closed
              ? (u) => _adminSetPresence(context, ref, u)
              : null,
        ),
        if (isAdmin && !closed)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              'Mantén presionado un jugador para marcarlo presente o ausente.',
              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Future<void> _adminSetPresence(
    BuildContext context,
    WidgetRef ref,
    AppUser u,
  ) async {
    final played = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              'Presencia de ${u.name}',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: const Text('Jugó'),
            onTap: () => Navigator.pop(ctx, true),
          ),
          ListTile(
            leading: const Icon(Icons.cancel, color: Colors.red),
            title: const Text('No fue'),
            onTap: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
    if (played == null) return;
    final myUid = ref.read(myUidProvider);
    fireAndForget(
      ref.read(repoProvider).setPresence(match.id, u.uid, played, setBy: myUid),
      success: '${u.name}: ${played ? 'jugó' : 'no fue'}',
    );
  }

  Future<void> _passList(
    BuildContext context,
    WidgetRef ref,
    List<AppUser> users,
    Map<String, Attendance> attendance,
  ) async {
    // Prellenado: presencia ya marcada; si no hay, la intención "Voy".
    final initial = <String, bool>{
      for (final u in users)
        u.uid:
            attendance[u.uid]?.played ??
            (attendance[u.uid]?.status == AttendanceStatus.yes),
    };
    final result = await showModalBottomSheet<Map<String, bool>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _PassListSheet(users: users, initial: initial),
    );
    if (result == null) return;
    final myUid = ref.read(myUidProvider);
    fireAndForget(
      ref.read(repoProvider).setPresenceBulk(match.id, result, setBy: myUid),
      success:
          'Lista guardada: ${result.values.where((v) => v).length} presentes',
    );
  }
}

class _PassListSheet extends StatefulWidget {
  const _PassListSheet({required this.users, required this.initial});

  final List<AppUser> users;
  final Map<String, bool> initial;

  @override
  State<_PassListSheet> createState() => _PassListSheetState();
}

class _PassListSheetState extends State<_PassListSheet> {
  late final Map<String, bool> _value = Map.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final count = _value.values.where((v) => v).length;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (ctx, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                Expanded(child: Text('Pasar lista', style: text.titleLarge)),
                Text('$count presentes', style: text.labelLarge),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              children: [
                for (final u in widget.users)
                  CheckboxListTile(
                    value: _value[u.uid] ?? false,
                    onChanged: (v) =>
                        setState(() => _value[u.uid] = v ?? false),
                    secondary: PlayerAvatar(user: u, radius: 18),
                    title: Text(u.name),
                    controlAffinity: ListTileControlAffinity.trailing,
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              8,
              20,
              16 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Row(
              children: [
                TextButton(
                  onPressed: () =>
                      setState(() => _value.updateAll((_, __) => false)),
                  child: const Text('Ninguno'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancelar'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, _value),
                  icon: const Icon(Icons.save),
                  label: const Text('Guardar'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- grupos

class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.users,
    required this.icon,
    required this.color,
    this.subtitleOf,
    this.onLongPress,
  });

  final String title;
  final List<AppUser> users;
  final IconData icon;
  final Color color;
  final String Function(AppUser)? subtitleOf;
  final void Function(AppUser)? onLongPress;

  @override
  Widget build(BuildContext context) {
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
            subtitle: subtitleOf == null ? null : Text(subtitleOf!(u)),
            trailing: Icon(icon, color: color, size: 20),
            onLongPress: onLongPress == null ? null : () => onLongPress!(u),
          ),
      ],
    );
  }
}
