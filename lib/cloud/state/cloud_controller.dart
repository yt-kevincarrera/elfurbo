import 'dart:async';
import 'dart:io';

import '../api/api_client.dart';
import '../auth/session.dart';
import '../sync/club_data.dart';
import '../sync/command.dart';
import '../sync/local_store.dart';
import '../sync/reducers.dart';
import '../sync/sync_engine.dart';

/// Un servidor del que soy miembro (de `GET /me`).
class MyClub {
  const MyClub({
    required this.id,
    required this.name,
    required this.status,
    required this.memberId,
    required this.role,
  });

  final String id;
  final String name;
  final String status;
  final String memberId;
  final String role;

  factory MyClub.fromJson(Map<String, dynamic> j) => MyClub(
    id: j['id'] as String,
    name: j['name'] as String,
    status: j['status'] as String,
    memberId: j['memberId'] as String,
    role: j['role'] as String,
  );
}

/// Una solicitud de servidor mía (pendiente o rechazada).
class ClubRequest {
  const ClubRequest({
    required this.id,
    required this.name,
    required this.status,
    this.reviewNote,
  });

  final String id;
  final String name;
  final String status;
  final String? reviewNote;

  factory ClubRequest.fromJson(Map<String, dynamic> j) => ClubRequest(
    id: j['id'] as String,
    name: j['name'] as String,
    status: j['status'] as String,
    reviewNote: j['reviewNote'] as String?,
  );
}

class Me {
  const Me({required this.user, required this.clubs, required this.requests});

  final CloudUser user;
  final List<MyClub> clubs;
  final List<ClubRequest> requests;

  factory Me.fromJson(Map<String, dynamic> j) => Me(
    user: CloudUser.fromJson(j['user'] as Map<String, dynamic>),
    clubs: [
      for (final c in (j['clubs'] as List))
        MyClub.fromJson(c as Map<String, dynamic>),
    ],
    requests: [
      for (final r in ((j['clubRequests'] as List?) ?? const []))
        ClubRequest.fromJson(r as Map<String, dynamic>),
    ],
  );
}

/// Vista previa de una invitación antes de aceptarla.
class InvitePreview {
  const InvitePreview({
    required this.clubId,
    required this.clubName,
    required this.role,
    this.claimName,
  });

  final String clubId;
  final String clubName;
  final String role;

  /// Si la invitación es para reclamar un perfil sin cuenta, su nombre.
  final String? claimName;
}

/// Todo lo de la cuenta en un sitio: sesión, `/me`, la cola de cambios y el
/// sync. La interfaz lo usa a través de los providers de `providers.dart`.
class CloudController {
  CloudController({
    required this.api,
    required this.sessions,
    required this.dataRoot,
    this.isOutdated,
    this.gate,
  }) {
    _session = sessions.read();
    api.token = _session?.token;
    if (_session != null) _openStore(_session!.user.id);
  }

  final ApiClient api;
  final SessionStore sessions;

  /// Carpeta privada de la app; dentro, una subcarpeta por cuenta.
  final Directory dataRoot;

  /// Ver [SyncEngine.isOutdated] y [SyncEngine.gate].
  final Future<bool> Function()? isOutdated;
  final Future<void> Function()? gate;

  Session? _session;
  Session? get session => _session;
  LocalStore? _store;
  SyncEngine? _engine;
  SyncEngine? get engine => _engine;
  Me? _me;
  Me? get me => _me;

  final _sessionChanges = StreamController<Session?>.broadcast();
  Stream<Session?> get sessionChanges => _sessionChanges.stream;
  final _meChanges = StreamController<Me?>.broadcast();
  Stream<Me?> get meChanges => _meChanges.stream;

  /// Los archivos de una cuenta (también los usa el sync de segundo plano).
  static LocalStore storeFor(Directory dataRoot, String userId) => LocalStore(
    Directory('${dataRoot.path}${Platform.pathSeparator}u-$userId'),
  );

  void _openStore(String userId) {
    _store = storeFor(dataRoot, userId);
    _engine = SyncEngine(
      api: api,
      store: _store!,
      isOutdated: isOutdated,
      gate: gate,
    );
  }

  AuthApi get _auth => AuthApi(api);

  Future<void> login(String username, String password) =>
      _start(_auth.login(username, password));

  Future<void> register({
    required String username,
    required String password,
    required String displayName,
  }) => _start(
    _auth.register(
      username: username,
      password: password,
      displayName: displayName,
    ),
  );

  Future<void> recover({
    required String username,
    required String code,
    required String newPassword,
  }) => _start(
    _auth.recover(username: username, code: code, newPassword: newPassword),
  );

  Future<void> _start(Future<Session> call) async {
    final s = await call;
    await _engine?.close();
    await sessions.write(s);
    _session = s;
    api.token = s.token;
    _openStore(s.user.id);
    _sessionChanges.add(s);
    await loadMe();
    unawaited(sync());
  }

  /// Sale y borra lo de esta cuenta en el teléfono. Si no hay señal, sale igual
  /// (la sesión del servidor caduca sola). Llamarla dos veces a la vez no falla.
  Future<void> logout() =>
      _logout ??= _doLogout().whenComplete(() => _logout = null);
  Future<void>? _logout;

  Future<void> _doLogout() async {
    _debounce?.cancel();
    _retry?.cancel();
    final store = _store;
    // Primero se para el sync en marcha: si no, volvería a escribir archivos tras borrarlos.
    await _closeSession();
    try {
      await _auth.logout();
    } catch (_) {
      // Sin señal o sesión ya caducada: se sale igual.
    }
    api.token = null;
    await store?.wipe();
  }

  /// Borra la cuenta en el servidor (hace falta señal y la contraseña) y sale
  /// borrando lo de esta cuenta en el teléfono. Su historial queda en cada
  /// servidor como "Jugador eliminado".
  Future<void> deleteAccount(String password) async {
    await api.delete('/me', {'password': password});
    _debounce?.cancel();
    _retry?.cancel();
    final store = _store;
    await _closeSession();
    api.token = null;
    await store?.wipe();
  }

  /// La sesión caducó (401): fuera, pero sin borrar nada. Si vuelve a entrar la misma
  /// persona, su carpeta sigue ahí y la cola se envía.
  Future<void> _expire() async {
    _debounce?.cancel();
    _retry?.cancel();
    await _closeSession();
    api.token = null;
  }

  /// Fuera de la sesión: el estado cambia al instante (nadie ve ya la sesión vieja)
  /// y después se espera a que el sync en marcha termine sin escribir nada más.
  Future<void> _closeSession() => _closing ??= () async {
    final engine = _engine;
    _engine = null;
    _store = null;
    _session = null;
    _me = null;
    _sessionChanges.add(null);
    _meChanges.add(null);
    await sessions.clear();
    await engine?.close();
  }().whenComplete(() => _closing = null);
  Future<void>? _closing;

  /// Lee `/me` del servidor; si no se puede (sin señal, 5xx, portal…), usa la última copia.
  Future<Me?> loadMe() async {
    final store = _store;
    if (store == null) return null;
    try {
      final j = (await api.get('/me'))!;
      if (_store != store) return _me; // Cambió la cuenta mientras tanto.
      await store.writeMe(j);
      _me = Me.fromJson(j);
    } on ApiException catch (e) {
      if (e.status == 401) {
        await _expire();
        return null;
      }
      _me ??= await _cachedMe(store);
    } catch (_) {
      _me ??= await _cachedMe(store);
    }
    _meChanges.add(_me);
    return _me;
  }

  Future<Me?> _cachedMe(LocalStore store) async {
    final cached = await store.readMe();
    return cached == null ? null : Me.fromJson(cached);
  }

  /// `/me` para la interfaz: primero la copia guardada (al instante, también sin
  /// señal), después lo que diga el servidor y cada cambio posterior.
  Stream<Me?> watchMe() async* {
    final store = _store;
    if (_me == null && store != null) _me = await _cachedMe(store);
    yield _me;
    unawaited(loadMe());
    yield* meChanges;
  }

  Future<InvitePreview> previewInvite(String code) async {
    final j = (await api.get('/invites/${Uri.encodeComponent(code.trim())}'))!;
    final claim = j['claim'] as Map?;
    return InvitePreview(
      clubId: (j['club'] as Map)['id'] as String,
      clubName: (j['club'] as Map)['name'] as String,
      role: j['role'] as String,
      claimName: claim?['displayName'] as String?,
    );
  }

  /// Entra en el servidor de la invitación y lo trae completo. Si la respuesta se
  /// perdió y al reintentar dice "ya se usó" o "ya eres miembro", se comprueba en
  /// `/me`: si ya estoy dentro de `clubId`, cuenta como éxito.
  Future<void> acceptInvite(String code, {String? clubId}) async {
    try {
      await api.post('/invites/${Uri.encodeComponent(code.trim())}/accept');
    } on Object catch (e) {
      final maybeJoined =
          e is OfflineException ||
          (e is ApiException &&
              (e.code == 'invite_invalid' || e.code == 'already_member'));
      if (clubId == null || !maybeJoined) rethrow;
      final me = await loadMe();
      if (!(me?.clubs.any((c) => c.id == clubId) ?? false)) rethrow;
    }
    await loadMe();
    await sync();
  }

  Future<void> requestClub({
    required String name,
    String description = '',
    String requestNote = '',
  }) async {
    await api.post('/clubs', {
      'name': name,
      'description': description,
      'requestNote': requestNote,
    });
    await loadMe();
  }

  /// Un cambio hecho en el teléfono: a la cola, visible al instante, y sync en un momento.
  Future<void> run(
    String clubId,
    String type,
    Map<String, Object?> payload,
  ) async {
    final engine = _engine;
    if (engine == null) return;
    await engine.enqueue(Command.create(clubId, type, payload));
    _scheduleSync();
  }

  Timer? _debounce;
  void _scheduleSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => unawaited(sync()));
  }

  Future<void> sync() async {
    final engine = _engine;
    if (engine == null) return;
    await engine.sync();
    if (engine != _engine) {
      // Otro cerró la sesión mientras tanto: se espera a que termine de cerrarla.
      await _closing;
      return;
    }
    final state = engine.last.state;
    _scheduleRetry(state, engine.last.pending);
    if (state == SyncState.unauthorized) {
      await _expire();
    } else if (state == SyncState.idle) {
      // Servidores nuevos, aprobados o de los que me echaron: el selector al día.
      await loadMe();
    }
  }

  /// Reintentos con espera creciente (5 s, 10 s, 20 s… hasta 5 min) mientras
  /// haya cambios por enviar y no se pueda: en cuanto vuelva la señal, salen.
  static const retryBase = Duration(seconds: 5);
  static const retryMax = Duration(minutes: 5);
  Timer? _retry;
  int _failures = 0;

  /// La espera tras [failures] fallos seguidos (1 = el primero).
  static Duration retryDelay(int failures) {
    final ms = retryBase.inMilliseconds * (1 << (failures - 1).clamp(0, 16));
    return Duration(milliseconds: ms.clamp(0, retryMax.inMilliseconds));
  }

  void _scheduleRetry(SyncState state, int pending) {
    _retry?.cancel();
    final failed = state == SyncState.offline || state == SyncState.error;
    if (!failed || pending == 0 || _engine == null) {
      _failures = 0;
      return;
    }
    _failures++;
    _retry = Timer(retryDelay(_failures), () => unawaited(sync()));
  }

  /// La vista de un servidor: lo último del servidor con mis cambios pendientes encima.
  Future<ClubData> view(String clubId) async {
    final store = _store;
    final engine = _engine;
    if (store == null || engine == null) return ClubData(clubId: clubId);
    final server = await store.readClub(clubId) ?? ClubData(clubId: clubId);
    final myMemberId = _me?.clubs
        .where((c) => c.id == clubId)
        .firstOrNull
        ?.memberId;
    return clubView(server, await engine.pending(), myMemberId: myMemberId);
  }

  Future<List<RejectedChange>> rejected() async =>
      await _store?.readRejected() ?? const [];

  void dispose() {
    _debounce?.cancel();
    _retry?.cancel();
    _engine?.dispose();
    _sessionChanges.close();
    _meChanges.close();
  }
}
