import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../core/app_messenger.dart';
import '../data/firestore_repo.dart';

/// Registra el dispositivo para notificaciones push y guarda el token FCM en
/// el perfil del usuario (las Cloud Functions lo usan para enviar).
class PushService {
  PushService(this._repo);

  final FirestoreRepo _repo;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<RemoteMessage>? _messageSub;
  String? _uid;

  Future<void> register(String uid) async {
    if (_uid == uid) return;
    await dispose();
    _uid = uid;
    final messaging = FirebaseMessaging.instance;
    try {
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) {
        await _repo.saveFcmToken(uid, token);
      }
    } catch (e) {
      debugPrint('Push: no se pudo obtener el token: $e');
    }
    _tokenSub = messaging.onTokenRefresh.listen((token) {
      fireAndForget(_repo.saveFcmToken(uid, token));
    });
    // Con la app abierta Android no muestra la notificación: mostramos un aviso.
    _messageSub = FirebaseMessaging.onMessage.listen((message) {
      final n = message.notification;
      if (n == null) return;
      showMessage([n.title, n.body].whereType<String>().join(' · '));
    });
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
    await _messageSub?.cancel();
    _tokenSub = null;
    _messageSub = null;
    _uid = null;
  }
}
