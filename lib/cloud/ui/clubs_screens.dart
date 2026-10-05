import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../services/local_notifications.dart';
import '../../ui/superadmin/superadmin_screen.dart';
import '../state/cloud_controller.dart';
import '../state/providers.dart';
import 'errors.dart';
import '../../ui/widgets/expressive.dart';

/// Cierra sesión. Si hay cambios sin enviar o rechazados sin revisar, avisa antes:
/// al salir se borran del teléfono los datos de la cuenta.
Future<void> confirmAndLogout(BuildContext context, WidgetRef ref) async {
  final cloud = ref.read(cloudProvider);
  final pending = (await cloud.engine?.pending())?.length ?? 0;
  final rejected = (await cloud.rejected()).length;
  if (!context.mounted) return;
  if (pending > 0 || rejected > 0) {
    final what = [
      if (pending > 0)
        pending == 1 ? '1 cambio sin enviar' : '$pending cambios sin enviar',
      if (rejected > 0)
        rejected == 1
            ? '1 cambio no aplicado'
            : '$rejected cambios no aplicados',
    ].join(' y ');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Te vas igual?'),
        content: Text('Tienes $what. Si sales ahora, se pierden.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop(false);
              cloud.sync();
            },
            child: const Text('Sincronizar primero'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Salir igual'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
  }
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          AppLoading(size: 40),
          SizedBox(width: 16),
          Text('Cerrando sesión…'),
        ],
      ),
    ),
  );
  // El diálogo lo cierra CloudGate al ver la sesión cerrada (esta pantalla ya no existe).
  await cloud.logout();
  // Que otra cuenta que entre después no reciba recordatorios de esta.
  await cancelRemindersQuietly();
}

/// Sin servidores: cómo entrar en uno o pedir el tuyo.
class NoClubsScreen extends ConsumerWidget {
  const NoClubsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).value;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('El Furbo'),
        actions: [
          if (ref.watch(isSuperadminProvider))
            IconButton(
              tooltip: 'Panel de superadmin',
              icon: const Icon(Icons.admin_panel_settings_outlined),
              onPressed: () => SuperadminScreen.open(context),
            ),
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () => confirmAndLogout(context, ref),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(cloudProvider).loadMe(),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '¿Qué bolá, ${me?.user.displayName ?? ''}?',
              style: text.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Todavía no estás en ningún servidor. Pídele a quien organiza tu grupo una invitación '
              '(un enlace o un código), o solicita un servidor propio.',
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => showJoinWithCode(context),
              icon: const Icon(Icons.vpn_key),
              label: const Text('Unirme con un código'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => showRequestClub(context),
              icon: const Icon(Icons.add),
              label: const Text('Solicitar un servidor'),
            ),
            if (me != null && me.requests.isNotEmpty) ...[
              const SizedBox(height: 32),
              Text('Mis solicitudes', style: text.titleMedium),
              for (final r in me.requests) ClubRequestTile(request: r),
            ],
          ],
        ),
      ),
    );
  }
}

class ClubRequestTile extends StatelessWidget {
  const ClubRequestTile({super.key, required this.request});

  final ClubRequest request;

  @override
  Widget build(BuildContext context) {
    final pending = request.status == 'pending';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(pending ? Icons.hourglass_top : Icons.block),
      title: Text(request.name),
      subtitle: Text(
        pending
            ? 'Esperando aprobación'
            : 'Rechazada${request.reviewNote == null || request.reviewNote!.isEmpty ? '' : ': ${request.reviewNote}'}',
      ),
    );
  }
}

/// Pide el código, enseña a qué servidor entra y lo acepta.
Future<void> showJoinWithCode(BuildContext context, {String? initialCode}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _JoinSheet(initialCode: initialCode),
    );

class _JoinSheet extends ConsumerStatefulWidget {
  const _JoinSheet({this.initialCode});

  final String? initialCode;

  @override
  ConsumerState<_JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends ConsumerState<_JoinSheet> {
  late final _code = TextEditingController(text: widget.initialCode);
  InvitePreview? _preview;
  bool _busy = false;
  String? _error;

  Future<void> _go(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cloud = ref.read(cloudProvider);
    final p = _preview;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Unirme con un código',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: widget.initialCode == null,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Código',
              hintText: 'ABCD-EFGH',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _preview = null),
          ),
          const SizedBox(height: 16),
          if (p != null) ...[
            Text('Vas a entrar en ${p.clubName}'),
            if (p.claimName != null)
              Text('Con el perfil de ${p.claimName} (y su historial).'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _go(() async {
                      await cloud.acceptInvite(_code.text, clubId: p.clubId);
                      if (context.mounted) Navigator.of(context).pop();
                    }),
              child: const Text('Entrar'),
            ),
          ] else
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _go(() async {
                      final preview = await cloud.previewInvite(_code.text);
                      if (mounted) setState(() => _preview = preview);
                    }),
              child: const Text('Ver invitación'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> showRequestClub(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _RequestClubSheet(),
    );

class _RequestClubSheet extends ConsumerStatefulWidget {
  const _RequestClubSheet();

  @override
  ConsumerState<_RequestClubSheet> createState() => _RequestClubSheetState();
}

class _RequestClubSheetState extends ConsumerState<_RequestClubSheet> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(cloudProvider)
          .requestClub(
            name: _name.text,
            description: _description.text,
            requestNote: _note.text,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Solicitar un servidor',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'El superadmin lo revisa y te avisa. Puedes tener hasta 3 activos o pendientes.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Nombre',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            decoration: const InputDecoration(
              labelText: 'Descripción (opcional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Nota para el superadmin (opcional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _send,
            child: const Text('Enviar solicitud'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

/// Me voy de un servidor (por la cola de sync). Mis goles se quedan en su
/// historial; para volver hace falta otra invitación.
Future<void> confirmLeave(
  BuildContext context,
  WidgetRef ref,
  MyClub club,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('¿Te vas de ${club.name}?'),
      content: const Text(
        'Dejas de verlo. Tus goles y asistencias se quedan en su historial, y para volver necesitas otra invitación.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Me quedo'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Me voy'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final cloud = ref.read(cloudProvider);
  await cloud.run(club.id, 'member.leave', {});
  showMessage(
    'Listo, te sales de ${club.name}. Si no hay señal, en cuanto vuelva.',
  );
  await cloud.sync();
}
