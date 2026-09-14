import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'local_notifications.dart';

/// Elimina la cuenta: baja del token, recordatorios, perfil en Firestore y
/// cuenta de Firebase Auth (reautentica con Google si hace falta). El
/// historial (asistencias, reportes, votos) queda a nombre de "Jugador".
Future<void> deleteAccountCompletely(WidgetRef ref) async {
  final uid = ref.read(myUidProvider);
  await ref.read(pushServiceProvider).unregister();
  await LocalNotifications.cancelReminders();
  if (uid.isNotEmpty) await ref.read(repoProvider).deleteUserDoc(uid);
  await ref.read(authServiceProvider).deleteAccount();
}

/// Cierra la sesión completa: da de baja el token de push de este teléfono
/// (para que otro usuario que entre después no reciba avisos ajenos), cancela
/// los recordatorios locales y sale de Firebase y Google.
Future<void> signOutCompletely(WidgetRef ref) async {
  await ref.read(pushServiceProvider).unregister();
  await LocalNotifications.cancelReminders();
  await ref.read(authServiceProvider).signOut();
}
