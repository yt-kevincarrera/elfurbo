import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/ui/home_screens.dart';
import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../domain/club_roles.dart';
import '../../domain/matchday_rules.dart';
import '../../models/app_user.dart';
import '../../models/season.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import '../widgets/guest_dialog.dart';
import 'audit_screen.dart';
import 'club_profile.dart';
import 'invites.dart';
import 'settings.dart';
import '../widgets/player_avatar.dart';

/// Admin del servidor (owner y admin): temporadas, miembros y jugadores sin
/// cuenta. Invitaciones, códigos de recuperación y ajustes llegan en el PR5b.
class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider).value ?? const [];
    final active = ref.watch(activeUsersProvider);
    final banned = users.where((u) => u.status == UserStatus.banned).toList();
    final seasons = ref.watch(seasonsProvider).value ?? const [];
    final matches = ref.watch(matchesProvider).value ?? const [];
    final myUid = ref.watch(myUidProvider);
    final myRole = ref.watch(myRoleProvider);
    final readOnly = ref.watch(clubReadOnlyProvider);
    final repo = ref.read(repoProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        actions: [
          IconButton(
            tooltip: 'Quién hizo qué',
            icon: const Icon(Icons.history),
            onPressed: () => AuditScreen.open(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (canManageInvites(myRole)) const InvitesSection(),
          if (canManageClub(myRole)) const ClubProfileSection(),
          if (canManageClub(myRole)) const ClubSettingsSection(),
          SectionTitle(
            'Temporadas',
            trailing: readOnly
                ? null
                : TextButton.icon(
                    onPressed: () => _newSeason(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Nueva'),
                  ),
          ),
          if (seasons.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                'Al crear la primera jornada se genera una temporada sola.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          GroupedSection(
            children: [
              for (final s in seasons)
                _SeasonTile(
                  season: s,
                  matchCount: matches.where((m) => m.seasonId == s.id).length,
                  seasons: seasons,
                ),
            ],
          ),
          SectionTitle(
            'Jugadores (${active.length})',
            trailing: readOnly
                ? null
                : TextButton.icon(
                    onPressed: () => _newGuest(context, ref),
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Sin cuenta'),
                  ),
          ),
          GroupedSection(
            children: [
              for (final u in active)
                ListTile(
                  leading: PlayerAvatar(user: u),
                  title: Text(u.name),
                  subtitle: Text(
                    [
                      roleLabel(u.role.name),
                      if (u.nickname != null && u.nickname!.isNotEmpty)
                        u.displayName,
                    ].join(' · '),
                  ),
                  trailing: u.uid == myUid
                      ? const Chip(
                          label: Text('Tú'),
                          visualDensity: VisualDensity.compact,
                        )
                      : _PlayerMenu(
                          user: u,
                          myRole: myRole,
                          readOnly: readOnly,
                        ),
                ),
            ],
          ),
          if (banned.isNotEmpty) ...[
            SectionTitle('Expulsados (${banned.length})'),
            GroupedSection(
              children: [
                for (final u in banned)
                  ListTile(
                    leading: PlayerAvatar(user: u),
                    title: Text(u.name),
                    subtitle: const Text(
                      'Para volver necesita otra invitación',
                    ),
                    trailing: readOnly || !canBan(myRole, u.role)
                        ? null
                        : TextButton(
                            onPressed: () => fireAndForget(
                              repo.unban(u.uid),
                              success:
                                  '${u.name} puede volver con una invitación',
                            ),
                            child: const Text('Perdonar'),
                          ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Un jugador sin cuenta: sus goles los pone el staff, y más adelante puede
  /// reclamar el perfil con una invitación.
  Future<void> _newGuest(BuildContext context, WidgetRef ref) async {
    final name = await askGuestName(context);
    if (name == null) return;
    fireAndForget(
      ref.read(repoProvider).createGuest(name),
      success: 'Listo, $name ya está en la lista',
    );
  }

  Future<void> _newSeason(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(
      text: 'Temporada ${DateTime.now().year}',
    );
    var activate = true;
    var startDate = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Nueva temporada'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nombre'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: startDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setState(() => startDate = picked);
                },
                icon: const Icon(Icons.calendar_today),
                label: Text('Desde ${Fmt.dateOnly(startDate)}'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Activar ahora'),
                subtitle: const Text(
                  'Las jornadas nuevas van a esta temporada. La tabla arranca de cero; el histórico se conserva.',
                ),
                value: activate,
                onChanged: (v) => setState(() => activate = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Crear'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    final repo = ref.read(repoProvider);
    fireAndForget(
      repo.createSeason(
        id: repo.newId(),
        name: name.text,
        startDate: startDate,
        activate: activate,
      ),
      success: 'Temporada creada',
    );
  }
}

class _SeasonTile extends ConsumerWidget {
  const _SeasonTile({
    required this.season,
    required this.matchCount,
    required this.seasons,
  });

  final Season season;
  final int matchCount;
  final List<Season> seasons;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = season;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        s.isClosed
            ? Icons.lock_outline
            : s.isActive
            ? Icons.radio_button_checked
            : Icons.radio_button_off,
        color: s.isActive && !s.isClosed ? scheme.primary : null,
      ),
      title: Text(
        s.name,
        style: TextStyle(
          fontWeight: s.isActive && !s.isClosed ? FontWeight.bold : null,
        ),
      ),
      subtitle: Text(
        [
          'Desde ${Fmt.dateOnly(s.startDate)}',
          Fmt.plural(matchCount, 'jornada', 'jornadas'),
          if (s.isClosed) 'cerrada' else if (s.isActive) 'activa',
        ].join(' · '),
      ),
      trailing: ref.watch(clubReadOnlyProvider)
          ? null
          : PopupMenuButton<String>(
              onSelected: (a) => _onAction(context, ref, a),
              itemBuilder: (_) => [
                if (!s.isActive && !s.isClosed)
                  const PopupMenuItem(
                    value: 'activate',
                    child: Text('Marcar como activa'),
                  ),
                const PopupMenuItem(value: 'edit', child: Text('Editar')),
                PopupMenuItem(
                  value: 'close',
                  child: Text(
                    s.isClosed ? 'Reabrir temporada' : 'Cerrar temporada',
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    'Eliminar',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final repo = ref.read(repoProvider);
    final s = season;
    switch (action) {
      case 'activate':
        fireAndForget(
          repo.activateSeason(s.id),
          success: '${s.name} es la temporada activa',
        );
      case 'edit':
        await _edit(context, ref);
      case 'close':
        if (s.isClosed) {
          fireAndForget(
            repo.setSeasonClosed(s.id, false),
            success: '${s.name} reabierta',
          );
          return;
        }
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('¿Cerrar ${s.name}?'),
            content: const Text(
              'Sus jornadas quedan congeladas: nadie podrá poner goles, confirmar ni votar. Puedes reabrirla cuando quieras.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Volver'),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Cerrar temporada'),
              ),
            ],
          ),
        );
        if (ok == true) {
          fireAndForget(
            repo.setSeasonClosed(s.id, true),
            success: '${s.name} cerrada',
          );
        }
      case 'delete':
        await _delete(context, ref);
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: season.name);
    var startDate = season.startDate;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Editar temporada'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nombre'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: startDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setState(() => startDate = picked);
                },
                icon: const Icon(Icons.calendar_today),
                label: Text('Desde ${Fmt.dateOnly(startDate)}'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || controller.text.trim().isEmpty) return;
    fireAndForget(
      ref
          .read(repoProvider)
          .updateSeason(season.id, name: controller.text, startDate: startDate),
      success: 'Temporada actualizada',
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repoProvider);
    final matches = ref.read(matchesProvider).value ?? const [];
    final mine = matches.where((m) => m.seasonId == season.id).toList();
    if (canDeleteSeason(season, matches)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('¿Eliminar ${season.name}?'),
          content: const Text('No tiene jornadas, así que no se pierde nada.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Volver'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar'),
            ),
          ],
        ),
      );
      if (ok == true) {
        fireAndForget(
          repo.deleteSeason(season.id),
          success: 'Temporada eliminada',
        );
      }
      return;
    }

    // El servidor no deja tocar una jornada cerrada (ni mover nada a una
    // temporada cerrada): si hay alguna, no se puede vaciar esta temporada.
    if (mine.any((m) => ref.read(matchClosedProvider(m.id)))) {
      showMessage(
        'Tiene jornadas ya cerradas y esas no se pueden mover. Si ya terminó, mejor ciérrala en vez de borrarla.',
      );
      return;
    }
    final others = seasons
        .where((s) => s.id != season.id && !s.isClosed)
        .toList();
    if (others.isEmpty) {
      showMessage(
        'Tiene ${Fmt.plural(mine.length, 'jornada', 'jornadas')} y no hay otra temporada abierta a la que moverlas.',
      );
      return;
    }
    final target = await showDialog<Season>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          'Mover ${Fmt.plural(mine.length, 'jornada', 'jornadas')} antes de eliminar',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '${season.name} tiene jornadas. Elige a qué temporada pasarlas; después se elimina.',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
          ),
          for (final s in others)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Text(s.name),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    if (target == null) return;
    fireAndForget(
      repo
          .moveMatchesToSeason(mine.map((m) => m.id), target.id)
          .then((_) => repo.deleteSeason(season.id)),
      success: 'Jornadas movidas a ${target.name} y temporada eliminada',
    );
  }
}

/// Lo que yo puedo hacer con otro miembro (la misma matriz que el servidor).
class _PlayerMenu extends ConsumerWidget {
  const _PlayerMenu({
    required this.user,
    required this.myRole,
    this.readOnly = false,
  });

  final AppUser user;
  final UserRole myRole;

  /// Servidor suspendido: los cambios no entran, pero un código sí se puede dar.
  final bool readOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repoProvider);
    final u = user;
    final roles = [
      if (!readOnly)
        for (final r in const [
          UserRole.admin,
          UserRole.scorer,
          UserRole.player,
        ])
          if (r != u.role && canSetRole(myRole, u.role, r)) r,
    ];
    final ban = !readOnly && canBan(myRole, u.role);
    final claim =
        !readOnly && u.isGuest && canInviteAs(myRole, UserRole.player);
    final code = !u.isGuest && canIssueRecoveryCode(myRole, u.role);
    final transfer = !readOnly && canManageClub(myRole) && !u.isGuest;
    if (roles.isEmpty && !ban && !claim && !code && !transfer) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<Object>(
      onSelected: (a) {
        if (a is UserRole) {
          fireAndForget(
            repo.setRole(u.uid, a),
            success: '${u.name} ahora es ${roleLabel(a.name).toLowerCase()}',
          );
        } else if (a == 'ban') {
          _confirmBan(context, ref);
        } else if (a == 'claim') {
          inviteToClaim(ref, u);
        } else if (a == 'code') {
          issueRecoveryCode(context, ref, u);
        } else if (a == 'transfer') {
          _confirmTransfer(context, ref);
        }
      },
      itemBuilder: (_) => [
        if (claim)
          const PopupMenuItem(
            value: 'claim',
            child: Text('Invitar a reclamar su perfil'),
          ),
        if (code)
          const PopupMenuItem(
            value: 'code',
            child: Text('Código de recuperación'),
          ),
        for (final r in roles)
          PopupMenuItem(
            value: r,
            child: Text('Hacer ${roleLabel(r.name).toLowerCase()}'),
          ),
        if (transfer)
          const PopupMenuItem(
            value: 'transfer',
            child: Text('Pasarle el servidor'),
          ),
        if (ban)
          PopupMenuItem(
            value: 'ban',
            child: Text(
              'Expulsar',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Future<void> _confirmTransfer(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Pasarle el servidor a ${user.name}?'),
        content: const Text(
          'Pasa a ser el dueño y tú te quedas de admin. Solo él podrá devolvértelo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Pasárselo'),
          ),
        ],
      ),
    );
    if (ok == true) {
      fireAndForget(
        ref.read(repoProvider).transferOwnership(user.uid),
        success: 'Listo, ${user.name} es el dueño',
      );
    }
  }

  Future<void> _confirmBan(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Expulsar a ${user.name}?'),
        content: const Text(
          'Deja de ver el servidor. Sus goles y asistencias se quedan en el historial.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Volver'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Expulsar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      fireAndForget(
        ref.read(repoProvider).ban(user.uid),
        success: '${user.name} expulsado',
      );
    }
  }
}
