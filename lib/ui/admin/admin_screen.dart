import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
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
                'Nadie esperando. Cuando alguien entre con Google aparece acá.',
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
                'Al crear el primer partido se genera una temporada automáticamente.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final s in seasons)
            ListTile(
              leading: Icon(
                s.isActive
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: s.isActive ? scheme.primary : null,
              ),
              title: Text(
                s.name,
                style: TextStyle(
                  fontWeight: s.isActive ? FontWeight.bold : null,
                ),
              ),
              subtitle: Text(
                'Desde ${Fmt.dateOnly(s.startDate)}${s.isActive ? ' · activa' : ''}',
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (a) {
                  if (a == 'activate') {
                    fireAndForget(
                      repo.activateSeason(
                        s.id,
                        seasons.map((x) => x.id).toList(),
                      ),
                      success: '${s.name} es la temporada activa',
                    );
                  } else if (a == 'rename') {
                    _renameSeason(context, ref, s);
                  }
                },
                itemBuilder: (_) => [
                  if (!s.isActive)
                    const PopupMenuItem(
                      value: 'activate',
                      child: Text('Marcar como activa'),
                    ),
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text('Renombrar'),
                  ),
                ],
              ),
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
                      label: Text('Vos'),
                      visualDensity: VisualDensity.compact,
                    )
                  : PopupMenuButton<String>(
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
                          const PopupMenuItem(
                            value: 'admin',
                            child: Text('Hacer admin'),
                          ),
                        if (u.isAdmin)
                          const PopupMenuItem(
                            value: 'player',
                            child: Text('Quitar admin'),
                          ),
                        const PopupMenuItem(
                          value: 'block',
                          child: Text('Bloquear'),
                        ),
                      ],
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Activar ahora'),
                subtitle: const Text(
                  'Los partidos nuevos van a esta temporada. La tabla arranca de cero; el histórico se conserva.',
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
            startDate: DateTime.now(),
            activate: activate,
            otherSeasonIds: seasons.map((s) => s.id).toList(),
          ),
      success: 'Temporada creada',
    );
  }

  Future<void> _renameSeason(
    BuildContext context,
    WidgetRef ref,
    Season season,
  ) async {
    final controller = TextEditingController(text: season.name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renombrar temporada'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    fireAndForget(ref.read(repoProvider).renameSeason(season.id, result));
  }
}
