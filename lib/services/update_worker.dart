import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'local_notifications.dart';
import 'update_service.dart';

/// Trabajo periódico con la app cerrada (Android WorkManager, cada 12 h):
/// busca versiones nuevas en GitHub Releases.
class UpdateWorker {
  static const uniqueName = 'app.elfurbo.updateCheck';
  static const taskName = 'updateCheck';

  /// Llamar una vez en `main()` (isolate principal) antes de `runApp`.
  static Future<void> initialize() async {
    await Workmanager().initialize(updateWorkerDispatcher);
  }

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
}

/// Punto de entrada del isolate de segundo plano. Debe ser función top-level
/// y conservarse tras tree-shaking (por eso el pragma).
@pragma('vm:entry-point')
void updateWorkerDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await _checkUpdate();
      return true;
    } catch (e) {
      debugPrint('UpdateWorker: falló el chequeo de versión: $e');
      return false; // WorkManager reintenta con backoff
    }
  });
}

Future<void> _checkUpdate() async {
  final release = await UpdateService.fetchLatest();
  if (release == null) return;
  final installed = await UpdateService.installedVersion();
  if (!release.isNewerThan(installed)) return;
  // Una sola notificación por versión.
  if (!await UpdateService.markNotified(release.tag)) return;
  await LocalNotifications.showUpdateAvailable(release);
}
