import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import '../domain/app_update.dart';
import 'update_service.dart';

/// Chequeo periódico de actualizaciones con la app cerrada (Android
/// WorkManager) que avisa con una notificación local. No necesita Firebase.
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
      final release = await UpdateService.fetchLatest();
      if (release == null) return true;
      final installed = await UpdateService.installedVersion();
      if (!release.isNewerThan(installed)) return true;
      // Una sola notificación por versión.
      if (!await UpdateService.markNotified(release.tag)) return true;
      await UpdateNotifications.showAvailable(release);
      return true;
    } catch (e) {
      debugPrint('UpdateWorker: falló el chequeo: $e');
      return false; // WorkManager reintenta con backoff
    }
  });
}

/// Notificación local "hay una versión nueva". Canal propio, separado del de
/// FCM (`elfurbo_default`), para que el usuario pueda silenciarlo aparte.
class UpdateNotifications {
  static const channelId = 'elfurbo_updates';
  static const notificationId = 4242;

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notification'),
      ),
    );
    _initialized = true;
  }

  static Future<void> showAvailable(AppRelease release) async {
    await _ensureInitialized();
    await _plugin.show(
      id: notificationId,
      title: 'Nueva versión de El Furbo',
      body: 'Ya está la ${release.version}. Tocá para actualizar.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          'Actualizaciones',
          channelDescription: 'Avisos de nuevas versiones de la app',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          color: Color(0xFF1B5E20),
        ),
      ),
      payload: release.tag,
    );
  }

  /// true si la app se abrió tocando la notificación de actualización.
  static Future<bool> launchedFromNotification() async {
    await _ensureInitialized();
    final details = await _plugin.getNotificationAppLaunchDetails();
    return details?.didNotificationLaunchApp == true &&
        details?.notificationResponse?.id == notificationId;
  }

  static Future<void> cancel() async {
    await _ensureInitialized();
    await _plugin.cancel(id: notificationId);
  }
}
