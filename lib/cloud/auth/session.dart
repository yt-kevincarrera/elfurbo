import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

/// Usuario de la cuenta (lo que devuelve la API, sin datos de servidores).
class CloudUser {
  const CloudUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.isSuperadmin,
  });

  final String id;
  final String username;
  final String displayName;
  final bool isSuperadmin;

  factory CloudUser.fromJson(Map<String, dynamic> j) => CloudUser(
    id: j['id'] as String,
    username: j['username'] as String,
    displayName: j['displayName'] as String,
    isSuperadmin: j['isSuperadmin'] == true,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'displayName': displayName,
    'isSuperadmin': isSuperadmin,
  };
}

class Session {
  const Session({required this.token, required this.user});

  final String token;
  final CloudUser user;
}

/// Guarda la sesión en el teléfono (almacenamiento privado de la app).
class SessionStore {
  SessionStore(this._prefs);

  final SharedPreferences _prefs;
  static const _key = 'cloud.session';

  Session? read() {
    final raw = _prefs.getString(_key);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return Session(
        token: j['token'] as String,
        user: CloudUser.fromJson(j['user'] as Map<String, dynamic>),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(Session s) => _prefs.setString(
    _key,
    jsonEncode({'token': s.token, 'user': s.user.toJson()}),
  );

  Future<void> clear() => _prefs.remove(_key);

  static const _clubKey = 'cloud.selectedClub';

  /// El servidor elegido en el selector: se abre el mismo al volver.
  String? readSelectedClub() => _prefs.getString(_clubKey);

  Future<void> writeSelectedClub(String clubId) =>
      _prefs.setString(_clubKey, clubId);
}

/// Llamadas de cuenta: entrar, crear cuenta, recuperar, salir.
class AuthApi {
  AuthApi(this._api);

  final ApiClient _api;

  Future<Session> register({
    required String username,
    required String password,
    required String displayName,
  }) => _session(
    _api.post('/auth/register', {
      'username': username,
      'password': password,
      'displayName': displayName,
      'deviceLabel': 'Android',
    }),
  );

  Future<Session> login(String username, String password) => _session(
    _api.post('/auth/login', {
      'username': username,
      'password': password,
      'deviceLabel': 'Android',
    }),
  );

  /// Con el código que le pasó un admin por WhatsApp.
  Future<Session> recover({
    required String username,
    required String code,
    required String newPassword,
  }) => _session(
    _api.post('/auth/recover', {
      'username': username,
      'code': code,
      'newPassword': newPassword,
      'deviceLabel': 'Android',
    }),
  );

  Future<void> logout() async {
    await _api.post('/auth/logout');
  }

  Future<Session> _session(Future<Map<String, dynamic>?> call) async {
    final j = (await call)!;
    return Session(
      token: j['token'] as String,
      user: CloudUser.fromJson(j['user'] as Map<String, dynamic>),
    );
  }
}
