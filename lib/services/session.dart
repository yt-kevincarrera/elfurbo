import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'local_notifications.dart';

/// Cierra la sesión completa: da de baja el token de push de este teléfono
/// (para que otro usuario que entre después no reciba avisos ajenos), cancela
/// los recordatorios locales y sale de Firebase y Google.
Future<void> signOutCompletely(WidgetRef ref) async {
  await ref.read(pushServiceProvider).unregister();
  await LocalNotifications.cancelReminders();
  await ref.read(authServiceProvider).signOut();
}
