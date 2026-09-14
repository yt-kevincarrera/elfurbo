import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../domain/matchday_rules.dart';
import '../../models/app_user.dart';
import '../../models/season.dart';
import '../widgets/common.dart';
import '../widgets/player_avatar.dart';

/// Panel del administrador: aprobar jugadores, roles y temporadas.
class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider).value ?? const [];
    final pending = users.where((u) => u.isPending).toList();
    final active = users.where((u) => u.isActive).toList();
    final blocked = users.where((u) => u.status == UserStatus.blocked).toList();
    final seasons = ref.watch(seasonsProvider).value ?? const [];
    final matches = ref.watch(matchesProvider).value ?? const [];
    final myUid = ref.watch(myUidProvider);
    final repo = ref.read(repoProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SectionTitle('Pendientes de aprobación (${pending.length})'),
          if (pending.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                'Nadie esperando. Cuando alguien entre con Google aparece aquí.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final u in pending)
            Card(
              child: ListTile(
                leading: PlayerAvatar(user: u),
                title: Text(u.displayName),
                subtitle: Text(u.email ?? ''),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.filled(
                      tooltip: 'Aprobar',
                      onPressed: () => fireAndForget(
                        repo.setUserStatus(u.uid, UserStatus.active),
                        success: '${u.displayName} ya puede entrar',
                      ),
                      icon: const Icon(Icons.check),
                    ),
                    IconButton(
                      tooltip: 'Rechazar',
                      onPressed: () => fireAndForget(
                        repo.setUserStatus(u.uid, UserStatus.blocked),
                      ),
                      icon: Icon(Icons.block, color: scheme.error),
                    ),
                  ],
                ),
              ),
            ),
          SectionTitle(
            'Temporadas',
            trailing: TextButton.icon(
              onPressed: () => _newSeason(context, ref, seasons),
              icon: const Icon(Icons.add),
              label: const Text('Nueva'),
            ),
          ),
          if (seasons.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                'Al crear la primera jornada se genera una temporada automáticamente.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final s in seasons)
            _SeasonTile(
              season: s,
              matchCount: matches.where((m) => m.seasonId == s.id).length,
              seasons: seasons,
            ),
          SectionTitle('Jugadores (${active.length})'),
          for (final u in active)
            ListTile(
              leading: PlayerAvatar(user: u),
              title: Text(u.name),
              subtitle: Text(
                [if (u.isAdmin) 'Admin', u.email ?? ''].join(' · '),
              ),
              trailing: u.uid == myUid
                  ? const Chip(
                      label: Text('Tú'),
                      visualDensity: VisualDensity.compact,
                    )
                  : _PlayerMenu(
                      user: u,
                      canDemote: canRemoveAdminRole(users, u.uid),
                    ),
            ),
          if (blocked.isNotEmpty) ...[
            SectionTitle('Bloqueados (${blocked.length})'),
            for (final u in blocked)
              ListTile(
                leading: PlayerAvatar(user: u),
                title: Text(u.displayName),
                subtitle: Text(u.email ?? ''),
                trailing: TextButton(
                  onPressed: () => fireAndForget(
                    repo.setUserStatus(u.uid, UserStatus.active),
                    success: '${u.displayName} desbloqueado',
                  ),
                  child: const Text('Desbloquear'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _newSeason(
    BuildContext context,
    WidgetRef ref,
    List<Season> seasons,
  ) async {
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
    fireAndForget(
      ref
          .read(repoProvider)
          .createSeason(
            name: name.text,
            startDate: startDate,
            activate: activate,
            otherSeasonIds: seasons.map((s) => s.id).toList(),
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
      trailing: PopupMenuButton<String>(
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
            child: Text(s.isClosed ? 'Reabrir temporada' : 'Cerrar temporada'),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              'Eliminar',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          repo.activateSeason(s.id, seasons.map((x) => x.id).toList()),
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
              'Sus jornadas quedan congeladas: nadie podrá cargar goles, confirmar ni votar. Puedes reabrirla cuando quieras.',
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

    final others = seasons.where((s) => s.id != season.id).toList();
    if (others.isEmpty) {
      showMessage(
        'Tiene ${Fmt.plural(mine.length, 'jornada', 'jornadas')} y no hay otra temporada a la que moverlas.',
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

class _PlayerMenu extends ConsumerWidget {
  const _PlayerMenu({required this.user, required this.canDemote});

  final AppUser user;

  /// false cuando es el único admin activo: no se le puede quitar el rol
  /// ni bloquear, o el grupo quedaría sin nadie que apruebe.
  final bool canDemote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repoProvider);
    final u = user;
    return PopupMenuButton<String>(
      onSelected: (a) {
        switch (a) {
          case 'admin':
            fireAndForget(
              repo.setUserRole(u.uid, UserRole.admin),
              success: '${u.name} ahora es admin',
            );
          case 'player':
            fireAndForget(
              repo.setUserRole(u.uid, UserRole.player),
              success: '${u.name} ya no es admin',
            );
          case 'block':
            fireAndForget(
              repo.setUserStatus(u.uid, UserStatus.blocked),
              success: '${u.name} bloqueado',
            );
        }
      },
      itemBuilder: (_) => [
        if (!u.isAdmin)
          const PopupMenuItem(value: 'admin', child: Text('Hacer admin')),
        if (u.isAdmin)
          PopupMenuItem(
            value: 'player',
            enabled: canDemote,
            child: Text(canDemote ? 'Quitar admin' : 'Es el único admin'),
          ),
        PopupMenuItem(
          value: 'block',
          enabled: canDemote,
          child: const Text('Bloquear'),
        ),
      ],
    );
  }
}
