import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:workmanager/workmanager.dart';

import '../cloud/api/api_client.dart';
import '../cloud/auth/session.dart';
import '../cloud/state/cloud_controller.dart';
import '../cloud/sync/sync_engine.dart';
import '../cloud/sync/alerts.dart';
import '../cloud/sync/local_store.dart';
import 'local_notifications.dart';
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

/// Avisa de lo nuevo que trajo el sync (ver `alerts.dart`). Con señal, antes
/// pone al día `/me` (servidores aprobados) y, si soy superadmin, las
/// solicitudes pendientes. Un fallo aquí no hace fallar el sync.
Future<void> _alert(
  ApiClient api,
  LocalStore store, {
  required bool online,
}) async {
  try {
    await initializeDateFormatting('es');
    tzdata.initializeTimeZones();
    List<Map<String, Object?>>? requests;
    if (online) {
      final me = await api.get('/me');
      if (me != null) await store.writeMe(me);
      if ((me?['user'] as Map?)?['isSuperadmin'] == true) {
        final j = await api.get('/admin/clubs?status=pending');
        requests = [
          for (final c in (j?['clubs'] as List?) ?? const [])
            Map<String, Object?>.from(c as Map),
        ];
      }
    }
    await LocalNotifications.showAlerts(
      await refreshAlerts(store, notify: true, requests: requests),
    );
  } catch (e) {
    debugPrint('Avisos: no se pudieron calcular: $e');
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
    final store = CloudController.storeFor(
      await getApplicationSupportDirectory(),
      session.user.id,
      // Si la app cerró la sesión mientras tanto, no se resucita la carpeta.
      createsRoot: false,
    );
    engine = SyncEngine(
      api: api,
      store: store,
      isOutdated: UpdateService.isOutdated,
    );
    await engine.sync();
    await _alert(api, store, online: engine.last.state == SyncState.idle);
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
