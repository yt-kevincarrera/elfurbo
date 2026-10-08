import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app.dart';
import '../../data/update_controller.dart';
import '../../ui/widgets/update_dialog.dart';
import '../../ui/superadmin/superadmin_screen.dart';
import '../../data/providers.dart';
import '../../ui/widgets/club_token.dart';
import '../../ui/widgets/tier_chip.dart';
import '../../ui/widgets/expressive.dart';
import '../state/cloud_controller.dart';
import '../state/providers.dart';
import '../sync/command.dart';
import '../sync/sync_engine.dart';
import 'club_picker.dart';
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

/// Barra de arriba del servidor: el servidor (y el selector si hay varios),
/// cómo va la sincronización, los cambios que no entraron y el menú de la cuenta.
class ClubBar extends ConsumerWidget {
  const ClubBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final club = ref.watch(currentClubProvider);
    if (club == null) return const SizedBox.shrink();
    // Nombre y color de la vista local: un cambio sin señal se ve al momento.
    final info = ref.watch(clubInfoProvider);
    final name = info?.name ?? club.name;
    // Un punto en el selector si hay algo pendiente en otro servidor.
    final elsewhere = ref
        .watch(pendingByClubProvider)
        .entries
        .any((e) => e.key != club.id && e.value > 0);
    final sync = ref.watch(syncStatusProvider).value;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final syncing = sync?.state == SyncState.syncing;
    final update = ref.watch(updateProvider);
    final downloading = update.phase == UpdatePhase.downloading;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => showClubPicker(context),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            ClubToken(
                              name: name,
                              color: info?.color ?? club.color,
                              tournament: club.isTournament,
                              size: 44,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          name,
                                          overflow: TextOverflow.ellipsis,
                                          style: text.titleMedium?.copyWith(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      // Solo los que pesan: oficial y verificado.
                                      if (Tier.parse(
                                        club.official ? 'official' : club.tier,
                                      ).trusted)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 4,
                                          ),
                                          child: TierChip.wire(
                                            club.official
                                                ? 'official'
                                                : club.tier,
                                            compact: true,
                                          ),
                                        ),
                                      Badge(
                                        isLabelVisible: elsewhere,
                                        smallSize: 8,
                                        child: Icon(
                                          Icons.unfold_more,
                                          size: 18,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 250),
                                    child: Text(
                                      sync == null ? ' ' : syncLabel(sync),
                                      key: ValueKey(
                                        sync == null ? '' : syncLabel(sync),
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                      style: text.labelMedium?.copyWith(
                                        color: switch (sync?.state) {
                                          SyncState.error ||
                                          SyncState.unauthorized ||
                                          SyncState.outdated => scheme.error,
                                          _ => scheme.onSurfaceVariant,
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if ((sync?.rejected ?? 0) > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: ActionChip(
                        avatar: Icon(
                          Icons.error_outline,
                          size: 18,
                          color: scheme.onErrorContainer,
                        ),
                        label: Text('${sync!.rejected}'),
                        labelStyle: text.labelLarge?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                        backgroundColor: scheme.errorContainer,
                        tooltip: 'Cambios no aplicados',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const RejectedChangesScreen(),
                          ),
                        ),
                      ),
                    ),
                  if (update.pending)
                    IconButton(
                      tooltip: switch (update.phase) {
                        UpdatePhase.ready => 'Instalar la versión nueva',
                        UpdatePhase.downloading =>
                          'Descargando la versión nueva',
                        _ => 'Hay una versión nueva',
                      },
                      onPressed: () => openUpdate(context, ref),
                      icon: Badge(
                        smallSize: 9,
                        isLabelVisible: !downloading,
                        child: Icon(
                          update.phase == UpdatePhase.ready
                              ? Icons.install_mobile
                              : Icons.system_update,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Sincronizar',
                    onPressed: syncing
                        ? null
                        : () => ref.read(cloudProvider).sync(),
                    icon: Icon(
                      sync?.state == SyncState.offline
                          ? Icons.cloud_off_outlined
                          : Icons.sync,
                    ),
                  ),
                  const _AccountMenu(),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              child: syncing || downloading
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: WavyProgressBar(
                        height: 8,
                        value: !syncing && (update.progress ?? -1) >= 0
                            ? update.progress
                            : null,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            if (club.status == 'suspended')
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(16),
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
    final club = ref.watch(currentClubProvider);
    final superadmin = ref.watch(isSuperadminProvider);
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
          case 'leave':
            if (club != null) confirmLeave(context, ref, club);
          case 'superadmin':
            SuperadminScreen.open(context);
          case 'logout':
            confirmAndLogout(context, ref);
        }
      },
      itemBuilder: (_) => [
        if (superadmin)
          const PopupMenuItem(
            value: 'superadmin',
            child: Text('Panel de superadmin'),
          ),
        const PopupMenuItem(value: 'join', child: Text('Unirme con un código')),
        const PopupMenuItem(
          value: 'request',
          child: Text('Solicitar un servidor'),
        ),
        const PopupMenuItem(
          value: 'rejected',
          child: Text('Cambios no aplicados'),
        ),
        // El dueño no se puede ir sin pasarle el servidor a otro.
        if (club != null && club.role != 'owner' && club.status != 'suspended')
          const PopupMenuItem(
            value: 'leave',
            child: Text('Salir de este servidor'),
          ),
        const PopupMenuItem(value: 'logout', child: Text('Cerrar sesión')),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: LoadingView(message: 'Un momentico…'));
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
    SyncState.outdated => 'Actualiza para seguir sincronizando',
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
      SyncState.outdated => Icons.system_update,
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
