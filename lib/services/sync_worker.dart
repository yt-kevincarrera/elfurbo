import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../cloud/api/api_client.dart';
import '../cloud/auth/session.dart';
import '../cloud/state/cloud_controller.dart';
import '../cloud/sync/sync_engine.dart';
import '../cloud/sync/local_store.dart';
import 'update_service.dart';

/// Sync con la app cerrada (Android WorkManager, spec §5):
/// - Cada ~15 min (el mínimo de Android, cuando el sistema lo permite) con
///   cualquier conexión: envía la cola y trae lo nuevo.
/// - Al salir de la app con cambios por enviar, uno suelto en cuanto haya
///   conexión, para no esperar al siguiente turno.
///
/// Puede coincidir con la app abierta: la cola es un archivo por cambio (ver
/// [LocalStore]), así que lo peor es enviar un cambio dos veces, y el servidor
/// lo reconoce como duplicado.
class SyncWorker {
  const SyncWorker();

  static const periodicName = 'app.elfurbo.sync';
  static const periodicTask = 'sync';
  static const flushName = 'app.elfurbo.syncNow';
  static const flushTask = 'syncNow';

  static bool handles(String task) => task == periodicTask || task == flushTask;

  /// Programa (o mantiene) el sync periódico. Idempotente.
  Future<void> schedule() async {
    try {
      await Workmanager().registerPeriodicTask(
        periodicName,
        periodicTask,
        frequency: const Duration(minutes: 15),
        initialDelay: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
    } catch (e) {
      debugPrint('SyncWorker: no se pudo programar: $e');
    }
  }

  /// Envía la cola en cuanto haya conexión, aunque la app esté cerrada.
  Future<void> flushWhenOnline() async {
    try {
      await Workmanager().registerOneOffTask(
        flushName,
        flushTask,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        constraints: Constraints(networkType: NetworkType.connected),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(seconds: 30),
      );
    } catch (e) {
      debugPrint('SyncWorker: no se pudo encargar el envío: $e');
    }
  }
}

/// Para la interfaz (en tests, uno que no hace nada).
final syncWorkerProvider = Provider<SyncWorker>((ref) => const SyncWorker());

/// Un sync en segundo plano. true si terminó bien o no había nada que hacer;
/// false para que WorkManager lo reintente más tarde.
Future<bool> runBackgroundSync() async {
  SyncEngine? engine;
  final api = ApiClient(build: await UpdateService.installedBuild());
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // la app pudo cambiar la sesión desde otro isolate
    final session = SessionStore(prefs).read();
    if (session == null) return true;
    api.token = session.token;
    engine = SyncEngine(
      api: api,
      store: CloudController.storeFor(
        await getApplicationSupportDirectory(),
        session.user.id,
      ),
      isOutdated: UpdateService.isOutdated,
    );
    await engine.sync();
    // Sin señal o el servidor falló: otra vez más tarde. Lo demás (al día,
    // sesión caducada, versión vieja) no mejora reintentando.
    return switch (engine.last.state) {
      SyncState.offline || SyncState.error => false,
      _ => true,
    };
  } finally {
    await engine?.close();
    api.close();
  }
}
