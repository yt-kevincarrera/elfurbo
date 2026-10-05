import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'local_notifications.dart';
import 'sync_worker.dart';
import 'update_service.dart';

/// Actualizaciones con la app cerrada (Android WorkManager):
/// - Cada 12 h, con cualquier conexión, mira si hay versión nueva.
///   Si la hay, avisa y encarga la descarga.
/// - La descarga espera a una red sin medidor (wifi): bajar 20 MB solo, con
///   datos móviles, saldría caro. Al terminar avisa "lista para instalar" y
///   tocar el aviso abre el instalador.
class UpdateWorker {
  static const uniqueName = 'app.elfurbo.updateCheck';
  static const taskName = 'updateCheck';
  static const downloadName = 'app.elfurbo.updateDownload';
  static const downloadTask = 'updateDownload';

  /// Programa (o mantiene) el chequeo periódico. Idempotente.
  static Future<void> schedule() async {
    try {
      await Workmanager().registerPeriodicTask(
        uniqueName,
        taskName,
        frequency: UpdateService.checkInterval,
        initialDelay: const Duration(hours: 1),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 30),
      );
    } catch (e) {
      debugPrint('UpdateWorker: no se pudo programar: $e');
    }
  }

  /// Encarga bajar la versión nueva cuando haya wifi (una sola vez).
  static Future<void> scheduleDownload() => Workmanager().registerOneOffTask(
    downloadName,
    downloadTask,
    existingWorkPolicy: ExistingWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.unmetered),
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 15),
  );
}

/// Todo el trabajo de segundo plano entra por aquí (actualizaciones y sync).
abstract final class BackgroundWork {
  /// Llamar una vez en `main()` (isolate principal) antes de `runApp`.
  static Future<void> initialize() async {
    await Workmanager().initialize(backgroundDispatcher);
  }
}

/// Punto de entrada del isolate de segundo plano. Debe ser función top-level
/// y conservarse tras tree-shaking (por eso el pragma).
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      if (SyncWorker.handles(task)) return await runBackgroundSync();
      if (task == UpdateWorker.downloadTask) {
        await _downloadUpdate();
      } else {
        await _checkUpdate();
      }
      return true;
    } catch (e) {
      debugPrint('Segundo plano: falló $task: $e');
      return false; // WorkManager reintenta con backoff
    }
  });
}

Future<void> _checkUpdate() async {
  final release = await UpdateService.fetchLatest();
  if (release == null) return;
  final installed = await UpdateService.installedVersion();
  if (!release.isNewerThan(installed)) return;
  // Un solo aviso por versión; la descarga, cuando haya wifi.
  if (await UpdateService.markNotified(release.tag, kind: 'available')) {
    await LocalNotifications.showUpdateAvailable(release);
  }
  await UpdateWorker.scheduleDownload();
}

Future<void> _downloadUpdate() async {
  final service = UpdateService();
  try {
    final release = await service.lastKnown();
    if (release == null) return; // ya instalada o nunca vista
    final asset = await service.assetForDevice(release);
    if (asset == null) return;
    await service.download(asset);
    if (await UpdateService.markNotified(release.tag, kind: 'ready')) {
      await LocalNotifications.showUpdateReady(release);
    }
  } finally {
    service.dispose();
  }
}
