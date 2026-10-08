import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/api/directory_api.dart';
import '../../cloud/state/providers.dart';
import '../../cloud/ui/errors.dart';
import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../profile/global_stats.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';

/// Quién pidió entrar (owner y admin de un servidor público, o con
/// solicitudes que quedaron de cuando lo era). Tocar a alguien abre su perfil
/// de toda la app, para saber a quién se acepta. Necesita señal.
class JoinRequestsSection extends ConsumerWidget {
  const JoinRequestsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final club = ref.watch(currentClubProvider);
    final info = ref.watch(clubInfoProvider);
    if (club == null) return const SizedBox.shrink();
    final waiting = ref.watch(meProvider).value?.pendingJoins[club.id] ?? 0;
    // Uno privado sin solicitudes pendientes no tiene nada que enseñar aquí.
    if (!(info?.isPublic ?? false) && waiting == 0) {
      return const SizedBox.shrink();
    }
    final requests = ref.watch(joinRequestsProvider(club.id));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          'Quieren entrar',
          trailing: IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(joinRequestsProvider(club.id)),
          ),
        ),
        requests.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: AppLoading(size: 36)),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              describeError(e),
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          data: (list) => list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    'Nadie esperando. Cuando alguien lo pida desde "Buscar '
                    'servidores", sale aquí.',
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : GroupedSection(
                  children: [
                    for (final r in list)
                      _RequestTile(clubId: club.id, request: r),
                  ],
                ),
        ),
      ],
    );
  }
}

class _RequestTile extends ConsumerStatefulWidget {
  const _RequestTile({required this.clubId, required this.request});

  final String clubId;
  final JoinRequest request;

  @override
  ConsumerState<_RequestTile> createState() => _RequestTileState();
}

class _RequestTileState extends ConsumerState<_RequestTile> {
  bool _busy = false;

  Future<void> _decide(bool accept) async {
    final r = widget.request;
    String note = '';
    if (!accept) {
      final n = await _askNote();
      if (n == null) return;
      note = n;
    }
    setState(() => _busy = true);
    try {
      final api = ref.read(directoryApiProvider);
      if (accept) {
        await api.accept(widget.clubId, r.id);
      } else {
        await api.reject(widget.clubId, r.id, note: note);
      }
      ref.invalidate(joinRequestsProvider(widget.clubId));
      final cloud = ref.read(cloudProvider);
      unawaited(cloud.loadMe());
      // El nuevo miembro llega con el próximo sync.
      if (accept) unawaited(cloud.sync());
      showMessage(
        accept
            ? 'Listo, ${r.displayName} ya está dentro'
            : 'Listo, no entra ${r.displayName}',
      );
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askNote() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿No aceptar a ${widget.request.displayName}?'),
        content: TextField(
          controller: controller,
          maxLength: 200,
          decoration: const InputDecoration(
            hintText: 'Por qué (opcional): "estamos llenos"…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('No aceptar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final text = Theme.of(context).textTheme;
    return ListTile(
      title: Text(r.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '@${r.username} · '
            '${r.played == 0 ? 'todavía sin jornadas' : '${Fmt.plural(r.played, 'jornada', 'jornadas')} y ${Fmt.goals(r.goals)} en la app'}',
            style: text.bodySmall,
          ),
          if (r.message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('“${r.message}”', style: text.bodyMedium),
            ),
          const SizedBox(height: 6),
          if (_busy)
            const AppLoading(size: 28)
          else
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => _decide(true),
                  child: const Text('Aceptar'),
                ),
                OutlinedButton(
                  onPressed: () => _decide(false),
                  child: const Text('No aceptar'),
                ),
              ],
            ),
        ],
      ),
      isThreeLine: true,
      onTap: () => GlobalPlayerScreen.open(
        context,
        r.userId,
        displayName: r.displayName,
      ),
    );
  }
}
