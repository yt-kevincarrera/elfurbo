import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../state/cloud_controller.dart';
import '../state/providers.dart';
import '../sync/command.dart';
import '../sync/sync_engine.dart';
import '../../app.dart';
import 'clubs_screens.dart';

/// Inicio con sesión: sin servidores, cómo conseguir uno; con servidor, la
/// app del servidor elegido (jornadas, tabla, perfil y admin).
class CloudHome extends ConsumerWidget {
  const CloudHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meAsync = ref.watch(meProvider);
    final me = meAsync.value;
    final club = ref.watch(currentClubProvider);
    if (me == null) {
      // Todavía no se sabe en qué servidores estoy: no decir "ninguno" a quien sí tiene.
      return meAsync.isLoading ? const _Loading() : const _NoConnection();
    }
    if (club == null) return const NoClubsScreen();
    return const ClubSession();
  }
}

/// Barra de arriba del servidor: selector, indicador de sync y menú de la cuenta.
class ClubBar extends ConsumerWidget {
  const ClubBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clubs = ref.watch(meProvider).value?.clubs ?? const [];
    final club = ref.watch(currentClubProvider);
    if (club == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Icon(Icons.sports_soccer, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClubSwitcher(clubs: clubs, current: club),
                  ),
                  const SyncIndicator(),
                  const _AccountMenu(),
                ],
              ),
            ),
            if (club.status == 'suspended')
              Container(
                width: double.infinity,
                color: scheme.errorContainer,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(
                  'Servidor suspendido: solo se puede consultar',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AccountMenu extends ConsumerWidget {
  const _AccountMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Servidores y cuenta',
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
            confirmAndLogout(context, ref);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'join', child: Text('Unirme con un código')),
        PopupMenuItem(value: 'request', child: Text('Solicitar un servidor')),
        PopupMenuItem(value: 'rejected', child: Text('Cambios no aplicados')),
        PopupMenuItem(value: 'logout', child: Text('Cerrar sesión')),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

/// Primera vez en este teléfono y sin señal: no hay nada guardado todavía.
class _NoConnection extends ConsumerWidget {
  const _NoConnection();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Sin conexión. La primera vez hace falta señal para traer tus servidores.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => ref.read(cloudProvider).loadMe(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    ),
  );
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

/// Nombre de un rol para la interfaz.
String roleLabel(String role) => switch (role) {
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
