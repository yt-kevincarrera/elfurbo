import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../data/update_controller.dart';
import 'expressive.dart';

/// Diálogo de la versión nueva: las notas, descargar e instalar. La descarga
/// es del `UpdateController`: cerrar el diálogo no la para.
Future<void> showUpdateDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _UpdateDialog(),
  );
}

/// Instala si ya está descargada; si no, abre el diálogo.
Future<void> openUpdate(BuildContext context, WidgetRef ref) async {
  if (ref.read(updateProvider).phase == UpdatePhase.ready) {
    try {
      await ref.read(updateProvider.notifier).install();
    } catch (e) {
      showError(e);
    }
    return;
  }
  await showUpdateDialog(context);
}

class _UpdateDialog extends ConsumerWidget {
  const _UpdateDialog();

  Future<void> _install(WidgetRef ref) async {
    try {
      await ref.read(updateProvider.notifier).install();
    } catch (e) {
      showError(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Si termina de descargarse con el diálogo abierto, al instalador directo.
    ref.listen(updateProvider, (prev, next) {
      if (prev?.phase == UpdatePhase.downloading &&
          next.phase == UpdatePhase.ready) {
        Navigator.of(context).pop();
        _install(ref);
      }
    });
    final s = ref.watch(updateProvider);
    final r = s.release;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (r == null) {
      return AlertDialog(
        title: const Text('Estás al día'),
        content: const Text('Ya tienes la última versión.'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Dale'),
          ),
        ],
      );
    }
    final progress = s.progress;
    final downloading = s.phase == UpdatePhase.downloading;

    return AlertDialog(
      icon: const Icon(Icons.system_update),
      title: Text('Versión ${r.version}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  r.notes.isNotEmpty
                      ? r.notes
                      : 'Hay una versión nueva de El Furbo lista para instalar.',
                  style: text.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (s.phase == UpdatePhase.ready)
              Text(
                'Ya está descargada: solo falta instalarla.',
                style: text.bodySmall?.copyWith(color: scheme.primary),
              )
            else
              Text(
                [
                  if ((s.asset?.size ?? 0) > 0)
                    'Pesa ${(s.asset!.size / (1024 * 1024)).round()} MB.',
                  'Mejor con wifi; si se corta, sigue donde se quedó.',
                ].join(' '),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            if (s.phase == UpdatePhase.failed) ...[
              const SizedBox(height: 8),
              Text(
                'No se pudo descargar. Cuando haya señal, dale otra vez: sigue donde se quedó.',
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            if (downloading) ...[
              const SizedBox(height: 20),
              WavyProgressBar(
                value: progress == null || progress < 0 ? null : progress,
              ),
              const SizedBox(height: 8),
              Text(
                progress == null || progress < 0
                    ? 'Descargando…'
                    : 'Descargando… ${(progress * 100).round()}%',
                style: text.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(downloading ? 'Seguir en segundo plano' : 'Más tarde'),
        ),
        if (!downloading)
          FilledButton.icon(
            onPressed: s.phase == UpdatePhase.ready
                ? () {
                    Navigator.of(context).pop();
                    _install(ref);
                  }
                : () => ref.read(updateProvider.notifier).download(),
            icon: Icon(
              s.phase == UpdatePhase.ready
                  ? Icons.install_mobile
                  : Icons.download,
            ),
            label: Text(
              s.phase == UpdatePhase.ready
                  ? 'Instalar'
                  : s.phase == UpdatePhase.failed
                  ? 'Reintentar'
                  : 'Actualizar',
            ),
          ),
      ],
    );
  }
}
