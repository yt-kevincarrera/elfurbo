import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import '../models/match_report.dart';
import 'local_notifications.dart';

/// Avisos que las Cloud Functions darían con Blaze, hechos desde el teléfono
/// en segundo plano (worker cada 12 h) con la sesión ya iniciada:
/// - Admin: jugadores esperando aprobación.
/// - Jugador presente en una jornada abierta: reportes ajenos que aún no
///   confirmó.
///
/// Guarda en preferencias el último número avisado para no repetir la misma
/// notificación en cada corrida.
class LocalChecks {
  LocalChecks._();

  static const _pendingUsersKey = 'checks.pendingUsers';
  static String _reportsKey(String matchId) => 'checks.reports.$matchId';

  /// Ventana en la que una jornada sigue abierta (ver `MatchDay.autoCloseAfter`).
  static const _openWindow = Duration(hours: 72);

  static Future<void> run() async {
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final db = FirebaseFirestore.instance;
    final prefs = await SharedPreferences.getInstance();

    final meSnap = await db.collection('users').doc(user.uid).get();
    if (!meSnap.exists) return;
    final me = AppUser.fromDoc(meSnap);
    if (!me.isActive) return;

    if (me.isAdmin) await _checkPendingUsers(db, prefs);
    await _checkReportsToConfirm(db, prefs, user.uid);
  }

  static Future<void> _checkPendingUsers(
    FirebaseFirestore db,
    SharedPreferences prefs,
  ) async {
    final snap = await db
        .collection('users')
        .where('status', isEqualTo: UserStatus.pending.name)
        .count()
        .get();
    final count = snap.count ?? 0;
    final last = prefs.getInt(_pendingUsersKey) ?? 0;
    if (count > last) await LocalNotifications.showPendingUsers(count);
    await prefs.setInt(_pendingUsersKey, count);
  }

  static Future<void> _checkReportsToConfirm(
    FirebaseFirestore db,
    SharedPreferences prefs,
    String uid,
  ) async {
    final now = DateTime.now();
    final matches = await db
        .collection('matches')
        .where('date', isGreaterThanOrEqualTo: now.subtract(_openWindow))
        .where('date', isLessThanOrEqualTo: now)
        .get();
    for (final m in matches.docs) {
      final status = m.data()['status'];
      if (status == 'cancelled' || status == 'closed') continue;
      final matchId = m.id;
      final mine = await db
          .collection('attendance')
          .doc('${matchId}_$uid')
          .get();
      if (mine.data()?['played'] != true) continue;

      final reports = await db
          .collection('reports')
          .where('matchId', isEqualTo: matchId)
          .get();
      final toConfirm = reports.docs
          .map(MatchReport.fromDoc)
          .where((r) => r.uid != uid && r.isPending)
          .where((r) => !r.confirmations.contains(uid))
          .length;
      final key = _reportsKey(matchId);
      final last = prefs.getInt(key) ?? 0;
      if (toConfirm > last) {
        await LocalNotifications.showReportsToConfirm(matchId, toConfirm);
      }
      await prefs.setInt(key, toConfirm);
    }
    debugPrint('LocalChecks: revisadas ${matches.size} jornadas');
  }
}
