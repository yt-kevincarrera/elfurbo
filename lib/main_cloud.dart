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
import 'cloud/ui/cloud_app.dart';

/// Arranque de la 1.0 con el backend propio (sin Firebase Auth ni Firestore).
///
///   flutter run -t lib/main_cloud.dart [--dart-define=API_URL=https://...]
///
/// Convive con `lib/main.dart` (la app actual) hasta el corte a la 1.0 (PR7).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  tzdata.initializeTimeZones();
  final prefs = await SharedPreferences.getInstance();
  final dir = await getApplicationSupportDirectory();
  final cloud = CloudController(
    api: ApiClient(),
    sessions: SessionStore(prefs),
    dataRoot: dir,
  );
  runApp(
    ProviderScope(
      overrides: [cloudProvider.overrideWithValue(cloud)],
      child: const CloudApp(),
    ),
  );
}
