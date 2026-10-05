import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'cloud/api/api_client.dart';
import 'cloud/auth/session.dart';
import 'cloud/state/cloud_controller.dart';
import 'cloud/sync/sync_handoff.dart';
import 'cloud/state/providers.dart';
import 'cloud/ui/cloud_app.dart';
import 'services/update_service.dart';
import 'services/update_worker.dart';

/// El Furbo 1.0, con el backend propio (sin Firebase Auth ni Firestore).
///
///   flutter run [--dart-define=API_URL=https://...]
///
/// Por defecto habla con staging (ver `apiBaseUrl`).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  tzdata.initializeTimeZones();
  // Con la app cerrada: versiones nuevas y la cola de cambios (WorkManager).
  await BackgroundWork.initialize();
  final handoff = ForegroundSyncHandoff();
  final prefs = await SharedPreferences.getInstance();
  final dir = await getApplicationSupportDirectory();
  final cloud = CloudController(
    api: ApiClient(),
    sessions: SessionStore(prefs),
    dataRoot: dir,
    isOutdated: UpdateService.isOutdated,
    gate: handoff.gate,
  );
  // El sync de segundo plano, si arranca con la app abierta, le pide a ella que sincronice.
  handoff.start(
    onSyncRequest: () {
      if (cloud.session != null) unawaited(cloud.sync());
    },
  );
  runApp(
    ProviderScope(
      overrides: [cloudProvider.overrideWithValue(cloud)],
      child: const CloudApp(),
    ),
  );
}
