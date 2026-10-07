import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'cloud/api/api_client.dart';
import 'cloud/auth/session.dart';
import 'cloud/state/cloud_controller.dart';
import 'cloud/state/providers.dart';
import 'core/deep_links.dart';
import 'cloud/ui/cloud_app.dart';
import 'services/local_notifications.dart';
import 'services/update_service.dart';
import 'services/update_worker.dart';

/// El Furbo, con el backend propio en Cloudflare (sin Google: desde Cuba no abre).
///
///   flutter run [--dart-define=API_URL=https://...]
///
/// Por defecto habla con producción (ver `apiBaseUrl`).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  tzdata.initializeTimeZones();
  // Con la app cerrada: versiones nuevas y la cola de cambios (WorkManager).
  await BackgroundWork.initialize();
  await DeepLinks.start();
  final prefs = await SharedPreferences.getInstance();
  final dir = await getApplicationSupportDirectory();
  final cloud = CloudController(
    api: ApiClient(build: await UpdateService.installedBuild()),
    sessions: SessionStore(prefs),
    dataRoot: dir,
    isOutdated: UpdateService.isOutdated,
    showAlerts: LocalNotifications.showAlerts,
  );
  runApp(
    ProviderScope(
      overrides: [cloudProvider.overrideWithValue(cloud)],
      child: const CloudApp(),
    ),
  );
}
