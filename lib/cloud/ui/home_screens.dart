import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../state/cloud_controller.dart';
import '../state/providers.dart';
import '../sync/command.dart';
import '../sync/sync_engine.dart';
import 'clubs_screens.dart';

/// Inicio con servidores: selector arriba, indicador de sync y el contenido del
/// servidor elegido. Las jornadas, la tabla y el perfil llegan en el PR5.
class CloudHome extends ConsumerWidget {
  const CloudHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).value;
    final club = ref.watch(currentClubProvider);
    if (me == null || club == null) return const NoClubsScreen();
    return Scaffold(
      appBar: AppBar(
        title: ClubSwitcher(clubs: me.clubs, current: club),
        actions: [
          const SyncIndicator(),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'join':
                  showJoinWithCode(context);
                case 'request':
                  showRequestClub(context);
                case 'rejected':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const RejectedChangesScreen(),
                    ),
                  );
                case 'logout':
                  ref.read(cloudProvider).logout();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'join', child: Text('Unirme con un código')),
              PopupMenuItem(
                value: 'request',
                child: Text('Solicitar un servidor'),
              ),
              PopupMenuItem(
                value: 'rejected',
                child: Text('Cambios no aplicados'),
              ),
              PopupMenuItem(value: 'logout', child: Text('Cerrar sesión')),
            ],
          ),
        ],
      ),
      body: ClubOverview(club: club),
    );
  }
}

class ClubSwitcher extends ConsumerWidget {
  const ClubSwitcher({super.key, required this.clubs, required this.current});

  final List<MyClub> clubs;
  final MyClub current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (clubs.length == 1) {
      return Text(current.name, overflow: TextOverflow.ellipsis);
    }
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: current.id,
        isExpanded: true,
        items: [
          for (final c in clubs)
            DropdownMenuItem(
              value: c.id,
              child: Text(c.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (id) {
          if (id != null) ref.read(selectedClubProvider.notifier).select(id);
        },
      ),
    );
  }
}

/// "Todo al día", "3 cambios por enviar" o "Sin conexión · último sync 14:32".
String syncLabel(SyncStatus s) {
  final when = s.lastSync == null
      ? ''
      : ' · último sync ${DateFormat.Hm('es').format(s.lastSync!.toLocal())}';
  return switch (s.state) {
    SyncState.syncing => 'Sincronizando…',
    SyncState.offline => 'Sin conexión$when',
    SyncState.error => 'No se pudo sincronizar$when',
    SyncState.unauthorized => 'Sesión caducada',
    SyncState.idle when s.pending > 0 =>
      s.pending == 1
          ? '1 cambio por enviar'
          : '${s.pending} cambios por enviar',
    SyncState.idle => 'Todo al día',
  };
}

class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncStatusProvider).value;
    if (s == null) return const SizedBox.shrink();
    final icon = switch (s.state) {
      SyncState.syncing => Icons.sync,
      SyncState.offline => Icons.cloud_off,
      SyncState.error || SyncState.unauthorized => Icons.sync_problem,
      SyncState.idle => s.pending > 0 ? Icons.cloud_upload : Icons.cloud_done,
    };
    return IconButton(
      tooltip: syncLabel(s),
      icon: Badge(
        isLabelVisible: s.rejected > 0,
        label: Text('${s.rejected}'),
        child: Icon(icon),
      ),
      onPressed: () {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(syncLabel(s))));
        ref.read(cloudProvider).sync();
      },
    );
  }
}

/// Lo que ya se puede ver del servidor: temporada activa y miembros.
class ClubOverview extends ConsumerWidget {
  const ClubOverview({super.key, required this.club});

  final MyClub club;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(clubViewProvider(club.id)).value;
    final text = Theme.of(context).textTheme;
    final members =
        [...?view?.all('member').where((m) => m['status'] == 'active')]..sort(
          (a, b) => '${a['displayName']}'.toLowerCase().compareTo(
            '${b['displayName']}'.toLowerCase(),
          ),
        );
    final season = view
        ?.all('season')
        .where((s) => s['isActive'] == true)
        .firstOrNull;
    return RefreshIndicator(
      onRefresh: () => ref.read(cloudProvider).sync(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (view?.club?['status'] == 'suspended')
            const Card(
              child: ListTile(
                leading: Icon(Icons.pause_circle),
                title: Text('Servidor suspendido: solo se puede consultar'),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.emoji_events_outlined),
            title: Text(
              season == null
                  ? 'Sin temporada activa'
                  : 'Temporada ${season['name']}',
            ),
            subtitle: const Text(
              'Las jornadas, la tabla y el perfil llegan en la próxima versión.',
            ),
          ),
          const Divider(),
          Text('Miembros (${members.length})', style: text.titleMedium),
          for (final m in members)
            ListTile(
              leading: CircleAvatar(
                child: Text(
                  '${m['displayName']}'.characters.first.toUpperCase(),
                ),
              ),
              title: Text('${m['displayName']}'),
              subtitle: Text(_roleLabel('${m['role']}')),
            ),
        ],
      ),
    );
  }
}

String _roleLabel(String role) => switch (role) {
  'owner' => 'Dueño',
  'admin' => 'Admin',
  'scorer' => 'Anotador',
  'guest' => 'Sin cuenta',
  _ => 'Jugador',
};

/// Cambios que el servidor no aceptó, con su motivo. El usuario los descarta.
class RejectedChangesScreen extends ConsumerStatefulWidget {
  const RejectedChangesScreen({super.key});

  @override
  ConsumerState<RejectedChangesScreen> createState() =>
      _RejectedChangesScreenState();
}

class _RejectedChangesScreenState extends ConsumerState<RejectedChangesScreen> {
  List<RejectedChange> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await ref.read(cloudProvider).rejected();
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cambios no aplicados')),
      body: _items.isEmpty
          ? const Center(child: Text('No hay cambios rechazados.'))
          : ListView(
              children: [
                for (final r in _items)
                  ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: Text(r.message),
                    subtitle: Text(
                      '${r.command.type} · ${DateFormat.yMd('es').add_Hm().format(r.command.clientAt.toLocal())}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Descartar',
                      icon: const Icon(Icons.close),
                      onPressed: () async {
                        await ref
                            .read(cloudProvider)
                            .engine
                            ?.dismissRejected(r.command.id);
                        await _load();
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}
