import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../core/app_messenger.dart';
import '../data/firestore_repo.dart';
import '../models/notification_payload.dart';
import 'notification_router.dart';

/// Push (FCM): registra el token de este teléfono en el perfil del usuario
/// (`fcmTokens`, uno por dispositivo), lo da de baja al cerrar sesión y abre
/// la pantalla correcta cuando el usuario toca una notificación.
class PushService {
  PushService(this._repo);

  final FirestoreRepo _repo;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<RemoteMessage>? _messageSub;
  StreamSubscription<RemoteMessage>? _openedSub;
  String? _uid;
  String? _token;

  Future<void> register(String uid) async {
    if (_uid == uid) return;
    await dispose();
    _uid = uid;
    final messaging = FirebaseMessaging.instance;
    try {
      await messaging.requestPermission();
      _token = await messaging.getToken();
      if (_token != null) {
        await _repo.addFcmToken(uid, _token!);
      }
    } catch (e) {
      debugPrint('Push: no se pudo obtener el token: $e');
    }
    _tokenSub = messaging.onTokenRefresh.listen((token) {
      _token = token;
      fireAndForget(_repo.addFcmToken(uid, token));
    });
    // Con la app abierta Android no muestra la notificación: mostramos un aviso.
    _messageSub = FirebaseMessaging.onMessage.listen((message) {
      final n = message.notification;
      if (n == null) return;
      showMessage([n.title, n.body].whereType<String>().join(' · '));
    });
    // Toque de una notificación con la app en segundo plano…
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen(_route);
    // …o la que abrió la app desde cero.
    try {
      final initial = await messaging.getInitialMessage();
      if (initial != null) _route(initial);
    } catch (e) {
      debugPrint('Push: sin mensaje inicial: $e');
    }
  }

  void _route(RemoteMessage message) {
    NotificationRouter.handle(NotificationPayload.fromFcmData(message.data));
  }

  /// Da de baja este teléfono del usuario actual (cierre de sesión). Sin
  /// esto, quien entre después en el mismo teléfono recibiría sus avisos.
  Future<void> unregister() async {
    final uid = _uid;
    final token = _token;
    if (uid != null && token != null) {
      try {
        await _repo.removeFcmToken(uid, token);
        await FirebaseMessaging.instance.deleteToken();
      } catch (e) {
        debugPrint('Push: no se pudo dar de baja el token: $e');
      }
    }
    await dispose();
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
    await _messageSub?.cancel();
    await _openedSub?.cancel();
    _tokenSub = null;
    _messageSub = null;
    _openedSub = null;
    _uid = null;
    _token = null;
  }
}
