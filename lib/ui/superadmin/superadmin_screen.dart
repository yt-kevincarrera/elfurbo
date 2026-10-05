import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderOrFamily;

import '../../cloud/api/admin_api.dart';
import '../../cloud/state/providers.dart';
import '../../cloud/ui/errors.dart';
import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../admin/invites.dart';
import '../widgets/chalk.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';

/// Servidores por estado (`pending`, `active`, `suspended`, `rejected`).
final _clubsProvider = FutureProvider.autoDispose
    .family<List<AdminClub>, String>(
      (ref, status) => ref.watch(superadminApiProvider).clubs(status: status),
    );

final _usersProvider = FutureProvider.autoDispose
    .family<List<AdminUser>, String>(
      (ref, query) => ref.watch(superadminApiProvider).users(query: query),
    );

final _metricsProvider = FutureProvider.autoDispose<Metrics>(
  (ref) => ref.watch(superadminApiProvider).metrics(),
);

/// Tu panel: aprobar servidores, suspender, usuarios y números. Necesita señal.
class SuperadminScreen extends StatelessWidget {
  const SuperadminScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const SuperadminScreen()));

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Superadmin'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Solicitudes'),
              Tab(text: 'Servidores'),
              Tab(text: 'Usuarios'),
              Tab(text: 'Números'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_Requests(), _Clubs(), _Users(), _Numbers()],
        ),
      ),
    );
  }
}

/// Lo que se muestra mientras carga, si falla o si no hay nada.
Widget _async<T>(
  AsyncValue<T> value,
  VoidCallback retry,
  Widget Function(T) data,
) => value.when(
  loading: () => const LoadingView(),
  error: (e, _) => EmptyState(
    icon: Icons.cloud_off,
    title: 'No se pudo traer',
    subtitle: describeError(e),
    action: FilledButton(onPressed: retry, child: const Text('Reintentar')),
  ),
  data: data,
);

/// Pide una nota opcional (para rechazar o suspender).
Future<String?> _askNote(
  BuildContext context,
  String title, {
  required String confirm,
}) async {
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: note,
        maxLength: 300,
        maxLines: 3,
        decoration: const InputDecoration(labelText: 'Motivo (opcional)'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Volver'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok == true ? note.text.trim() : null;
}

/// Ejecuta una acción del panel, avisa y refresca lo que haga falta. El
/// contenedor se toma antes de esperar: si cambias de pestaña o sales del panel
/// mientras tanto, esta pestaña ya no existe, pero la acción termina igual.
Future<void> _act(
  BuildContext context,
  Future<void> Function() action, {
  required String done,
  required List<ProviderOrFamily> refresh,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    await action();
    for (final p in refresh) {
      container.invalidate(p);
    }
    showMessage(done);
  } catch (e) {
    showError(describeError(e));
  }
}

class _Requests extends ConsumerStatefulWidget {
  const _Requests();

  @override
  ConsumerState<_Requests> createState() => _RequestsState();
}

class _RequestsState extends ConsumerState<_Requests> {
  /// Las que se están aprobando o rechazando (sin doble toque).
  final _busy = <String>{};

  Future<void> _run(String id, Future<void> Function() f) async {
    if (!_busy.add(id)) return;
    setState(() {});
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(superadminApiProvider);
    final cloud = ref.read(cloudProvider);
    final text = Theme.of(context).textTheme;
    return _async(
      ref.watch(_clubsProvider('pending')),
      () => ref.invalidate(_clubsProvider('pending')),
      (clubs) => clubs.isEmpty
          ? const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Nadie esperando',
              subtitle: 'Cuando alguien pida un servidor, sale aquí.',
            )
          : RefreshIndicator(
              onRefresh: () => ref.refresh(_clubsProvider('pending').future),
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 32),
                children: [
                  for (final c in clubs)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.name, style: text.headlineSmall),
                            Text(
                              '@${c.ownerUsername ?? '?'} · ${Fmt.short(c.createdAt)}',
                              style: AppTheme.mono(size: 12, color: Chalk.dim),
                            ),
                            if (c.requestNote.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text('“${c.requestNote}”', style: text.bodyLarge),
                            ],
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton(
                                    onPressed: _busy.contains(c.id)
                                        ? null
                                        : () => _run(
                                            c.id,
                                            () => _act(
                                              context,
                                              () async {
                                                await api.approve(c.id);
                                                // Si era mío, ya sale en el selector.
                                                await cloud.loadMe();
                                              },
                                              done: '${c.name} aprobado',
                                              refresh: [_clubsProvider],
                                            ),
                                          ),
                                    child: const Text('Aprobar'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _busy.contains(c.id)
                                        ? null
                                        : () async {
                                            final note = await _askNote(
                                              context,
                                              '¿Rechazar ${c.name}?',
                                              confirm: 'Rechazar',
                                            );
                                            if (note == null ||
                                                !context.mounted) {
                                              return;
                                            }
                                            await _run(
                                              c.id,
                                              () => _act(
                                                context,
                                                () => api.reject(
                                                  c.id,
                                                  note: note,
                                                ),
                                                done: '${c.name} rechazado',
                                                refresh: [_clubsProvider],
                                              ),
                                            );
                                          },
                                    child: const Text('Rechazar'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _Clubs extends ConsumerStatefulWidget {
  const _Clubs();

  @override
  ConsumerState<_Clubs> createState() => _ClubsState();
}

class _ClubsState extends ConsumerState<_Clubs> {
  String _status = 'active';

  @override
  Widget build(BuildContext context) {
    final api = ref.read(superadminApiProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              selected: {_status},
              onSelectionChanged: (s) => setState(() => _status = s.first),
              segments: const [
                ButtonSegment(value: 'active', label: Text('Activos')),
                ButtonSegment(value: 'suspended', label: Text('Suspendidos')),
                ButtonSegment(value: 'rejected', label: Text('Rechazados')),
              ],
            ),
          ),
        ),
        Expanded(
          child: _async(
            ref.watch(_clubsProvider(_status)),
            () => ref.invalidate(_clubsProvider(_status)),
            (clubs) => clubs.isEmpty
                ? const EmptyState(icon: Icons.dns_outlined, title: 'Ninguno')
                : ListView(
                    padding: const EdgeInsets.only(top: 8, bottom: 32),
                    children: [
                      GroupedSection(
                        children: [
                          for (final c in clubs)
                            ListTile(
                              title: Text(c.name),
                              subtitle: Text(
                                '@${c.ownerUsername ?? '?'} · ${Fmt.plural(c.members, 'miembro', 'miembros')}',
                              ),
                              trailing: switch (c.status) {
                                'active' => TextButton(
                                  onPressed: () async {
                                    final note = await _askNote(
                                      context,
                                      '¿Suspender ${c.name}?',
                                      confirm: 'Suspender',
                                    );
                                    if (note == null || !context.mounted) {
                                      return;
                                    }
                                    await _act(
                                      context,
                                      () => api.suspend(c.id, note: note),
                                      done: '${c.name} suspendido',
                                      refresh: [_clubsProvider],
                                    );
                                  },
                                  child: const Text('Suspender'),
                                ),
                                'suspended' => TextButton(
                                  onPressed: () => _act(
                                    context,
                                    () => api.reactivate(c.id),
                                    done: '${c.name} reactivado',
                                    refresh: [_clubsProvider],
                                  ),
                                  child: const Text('Reactivar'),
                                ),
                                _ => null,
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _Users extends ConsumerStatefulWidget {
  const _Users();

  @override
  ConsumerState<_Users> createState() => _UsersState();
}

class _UsersState extends ConsumerState<_Users> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final api = ref.read(superadminApiProvider);
    final myId = ref.watch(meProvider).value?.user.id;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            decoration: const InputDecoration(
              labelText: 'Buscar por usuario',
              prefixIcon: Icon(Icons.search),
            ),
            onSubmitted: (v) => setState(() => _query = v.trim()),
          ),
        ),
        Expanded(
          child: _async(
            ref.watch(_usersProvider(_query)),
            () => ref.invalidate(_usersProvider(_query)),
            (users) => users.isEmpty
                ? const EmptyState(
                    icon: Icons.person_search,
                    title: 'Nadie con ese nombre',
                  )
                : ListView(
                    padding: const EdgeInsets.only(top: 8, bottom: 32),
                    children: [
                      GroupedSection(
                        children: [
                          for (final u in users)
                            ListTile(
                              title: Text(u.displayName),
                              subtitle: Text(
                                [
                                  '@${u.username}',
                                  if (u.isSuperadmin) 'superadmin',
                                  if (u.status == 'suspended') 'suspendido',
                                  if (u.lastSeenAt != null)
                                    'visto el ${Fmt.dateOnly(u.lastSeenAt!)}',
                                ].join(' · '),
                              ),
                              trailing: u.id == myId
                                  ? null
                                  : PopupMenuButton<String>(
                                      onSelected: (a) async {
                                        switch (a) {
                                          case 'code':
                                            try {
                                              final code = await api
                                                  .recoveryCode(u.id);
                                              if (!context.mounted) return;
                                              await showRecoveryCode(
                                                context,
                                                forName: u.displayName,
                                                code: code,
                                              );
                                            } catch (e) {
                                              showError(describeError(e));
                                            }
                                          case 'suspend':
                                            await _act(
                                              context,
                                              () => api.suspendUser(u.id),
                                              done: '@${u.username} suspendido',
                                              refresh: [_usersProvider],
                                            );
                                          case 'unsuspend':
                                            await _act(
                                              context,
                                              () => api.unsuspendUser(u.id),
                                              done:
                                                  '@${u.username} puede volver a entrar',
                                              refresh: [_usersProvider],
                                            );
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                          value: 'code',
                                          child: Text('Código de recuperación'),
                                        ),
                                        if (!u.isSuperadmin &&
                                            u.status == 'suspended')
                                          const PopupMenuItem(
                                            value: 'unsuspend',
                                            child: Text('Quitar la suspensión'),
                                          )
                                        else if (!u.isSuperadmin)
                                          const PopupMenuItem(
                                            value: 'suspend',
                                            child: Text('Suspender'),
                                          ),
                                      ],
                                    ),
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _Numbers extends ConsumerWidget {
  const _Numbers();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _async(
      ref.watch(_metricsProvider),
      () => ref.invalidate(_metricsProvider),
      (m) => GridView.count(
        padding: const EdgeInsets.all(16),
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.5,
        children: [
          StatTile(label: 'Usuarios', value: '${m.users}', icon: Icons.people),
          StatTile(
            label: 'Activos 7 días',
            value: '${m.active7d}',
            icon: Icons.bolt,
          ),
          StatTile(
            label: 'Activos 30 días',
            value: '${m.active30d}',
            icon: Icons.calendar_month,
          ),
          StatTile(
            label: 'Cambios en 24 h',
            value: '${m.commands24h}',
            icon: Icons.sync,
          ),
          StatTile(
            label: 'Servidores activos',
            value: '${m.clubs['active'] ?? 0}',
            icon: Icons.dns,
          ),
          StatTile(
            label: 'Esperando',
            value: '${m.clubs['pending'] ?? 0}',
            icon: Icons.hourglass_bottom,
            color: Chalk.yellow,
          ),
        ],
      ),
    );
  }
}
