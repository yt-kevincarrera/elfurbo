import 'package:flutter/material.dart';

import '../../core/app_messenger.dart';
import '../../core/network_hints.dart';
import '../../domain/app_update.dart';
import '../../services/update_service.dart';

/// Diálogo "hay una versión nueva": muestra las notas y descarga e instala el
/// APK sin salir de la app.
Future<void> showUpdateDialog(
  BuildContext context, {
  required AppRelease release,
  required UpdateService service,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(release: release, service: service),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.release, required this.service});

  final AppRelease release;
  final UpdateService service;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null = sin empezar; -1 = tamaño desconocido
  bool _busy = false;

  Future<void> _update() async {
    setState(() {
      _busy = true;
      _progress = 0;
    });
    try {
      final abis = await UpdateService.supportedAbis();
      final asset = widget.release.assetFor(abis);
      if (asset == null) {
        throw Exception('La release no tiene un APK para este teléfono.');
      }
      final file = await widget.service.download(
        asset,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      await widget.service.install(file);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      showError(
        looksLikeBlockedNetwork(e)
            ? 'No se pudo descargar la actualización. $vpnHint'
            : e,
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final text = Theme.of(context).textTheme;
    final progress = _progress;

    return AlertDialog(
      icon: const Icon(Icons.system_update),
      title: Text('Nueva versión ${r.version}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (r.notes.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  child: Text(r.notes, style: text.bodyMedium),
                ),
              )
            else
              Text(
                'Hay una versión nueva de El Furbo lista para instalar.',
                style: text.bodyMedium,
              ),
            const SizedBox(height: 12),
            Text(
              'La descarga viene de GitHub. $vpnHint',
              style: text.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (progress != null) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(value: progress < 0 ? null : progress),
              const SizedBox(height: 8),
              Text(
                progress < 0
                    ? 'Descargando…'
                    : progress >= 1
                    ? 'Abriendo el instalador…'
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
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Más tarde'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _update,
          icon: const Icon(Icons.download),
          label: const Text('Actualizar'),
        ),
      ],
    );
  }
}
