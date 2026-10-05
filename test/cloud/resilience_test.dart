import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/auth/session.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/sync/command.dart';
import 'package:elfurbo/cloud/sync/local_store.dart';
import 'package:elfurbo/cloud/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = {
  'id': 'u1',
  'username': 'kevin',
  'displayName': 'Kevin',
  'isSuperadmin': false,
  'status': 'active',
};
const _me = {
  'user': _user,
  'clubs': [
    {
      'id': 'c1',
      'name': 'Pachanga',
      'status': 'active',
      'memberId': 'm1',
      'role': 'owner',
    },
  ],
  'clubRequests': [],
};

/// Un servidor configurable por ruta: cada test decide qué responde.
class Server {
  final calls = <String>[];
  FutureOr<http.Response> Function(http.Request req)? override;
  Object? pullError;
  Map<String, Object?> Function(Map<String, dynamic> cmd) pushResult = (c) => {
    'status': 'applied',
  };
  Map<String, dynamic> pull = {'clubs': {}, 'removed': []};
  Map<String, dynamic>? me = _me;

  MockClient get client => MockClient((req) async {
    calls.add('${req.method} ${req.url.path}');
    final o = override;
    if (o != null) {
      final res = await o(req);
      if (res.statusCode != 599) return res;
    }
    switch (req.url.path) {
      case '/auth/login':
        return http.Response(jsonEncode({'token': 'tok', 'user': _user}), 200);
      case '/auth/logout':
        return http.Response('', 204);
      case '/me':
        return http.Response(jsonEncode(me), 200);
      case '/sync/push':
        final cmds = (jsonDecode(req.body)['commands'] as List)
            .cast<Map<String, dynamic>>();
        return http.Response(
          jsonEncode({
            'results': [
              for (final c in cmds) {'id': c['id'], ...pushResult(c)},
            ],
          }),
          200,
        );
      case '/sync/pull':
        if (pullError != null) throw pullError!;
        return http.Response(jsonEncode(pull), 200);
    }
    return http.Response('{}', 404);
  });
}

/// "No intervengo": deja que responda el comportamiento por defecto.
final _pass = http.Response('', 599);

void main() {
  late Directory dir;
  late Server server;

  Future<CloudController> controller() async => CloudController(
    api: ApiClient(baseUrl: 'https://api.test', client: server.client),
    sessions: SessionStore(await SharedPreferences.getInstance()),
    dataRoot: dir,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('furbo-resil');
    server = Server();
  });
  tearDown(() async {
    // Puede quedar alguna escritura en vuelo del sync de fondo: no hace fallar el test.
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Ya no existe o la está usando otra operación que termina enseguida.
    }
  });

  test(
    'un 401 en el sync saca de la sesión pero NO borra la cola: al volver a entrar se envía',
    () async {
      final a = await controller();
      await a.login('kevin', 'secreto123');
      await a.sync(); // Deja terminar el sync que lanza el login.
      server.override = (req) => req.url.path == '/sync/push'
          ? http.Response(
              jsonEncode({
                'error': {
                  'code': 'session_expired',
                  'message': 'Tu sesión caducó',
                },
              }),
              401,
            )
          : _pass;
      await a.run('c1', 'member.createGuest', {
        'id': 'g1',
        'displayName': 'Yoandry',
      });
      await a.sync();
      expect(a.session, isNull);
      server.override = null;
      final b = await controller();
      await b.login('kevin', 'secreto123');
      expect(await b.engine!.pending(), hasLength(1));
    },
  );

  test(
    'un duplicate cuyo original fue rechazado aparece en "Cambios no aplicados"',
    () async {
      final a = await controller();
      await a.login('kevin', 'secreto123');
      server.pushResult = (c) => {
        'status': 'duplicate',
        'original': {
          'status': 'rejected',
          'code': 'forbidden',
          'message': 'No tienes permiso para hacer esto',
          'details': null,
        },
      };
      await a.run('c1', 'member.ban', {'memberId': 'm2'});
      await a.sync();
      final rejected = await a.rejected();
      expect(rejected.single.message, 'No tienes permiso para hacer esto');
      expect(await a.engine!.pending(), isEmpty);
    },
  );

  test(
    'si el push se aplica pero el pull falla, el cambio sigue en la vista hasta que llegue el pull',
    () async {
      final a = await controller();
      await a.login('kevin', 'secreto123');
      server.pullError = const SocketException('se cortó');
      await a.run('c1', 'member.createGuest', {
        'id': 'g1',
        'displayName': 'Yoandry',
      });
      await a.sync();
      expect((await a.view('c1')).one('member', 'g1'), isNotNull);
      server.pullError = null;
      server.pull = {
        'clubs': {
          'c1': {
            'cursor': 3,
            'hasMore': false,
            'snapshot': true,
            'upserts': {
              'member': [
                {
                  'id': 'g1',
                  'displayName': 'Yoandry',
                  'role': 'guest',
                  'status': 'active',
                },
              ],
            },
            'deletes': {},
          },
        },
        'removed': [],
      };
      await a.sync();
      expect((await a.view('c1')).one('member', 'g1'), isNotNull);
      expect(
        await a.engine!.pending(),
        isEmpty,
        reason: 'tras el pull ya no hace falta aplicarlo encima',
      );
    },
  );

  test(
    'cerrar sesión con un sync en marcha: no se recrean archivos ni hay errores, y salir dos veces no falla',
    () async {
      final a = await controller();
      await a.login('kevin', 'secreto123');
      final gate = Completer<void>();
      server.override = (req) async {
        if (req.url.path == '/sync/pull') await gate.future;
        return _pass;
      };
      await a.run('c1', 'member.createGuest', {'id': 'g1', 'displayName': 'A'});
      final syncing = a.sync();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final out1 = a.logout();
      final out2 = a.logout();
      gate.complete();
      await Future.wait([syncing, out1, out2]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        Directory('${dir.path}${Platform.pathSeparator}u-u1').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'TLS cortado es "sin conexión"; un 2xx que no es JSON es un error legible; nada deja el sync colgado',
    () async {
      final tls = ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient(
          (_) async => throw const HandshakeException('se cortó'),
        ),
      );
      expect(tls.get('/x'), throwsA(isA<OfflineException>()));
      final html = ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient(
          (_) async => http.Response('<html>portal cautivo</html>', 200),
        ),
      );
      expect(
        html.get('/x'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'bad_response'),
        ),
      );

      final store = LocalStore(dir);
      final engine = SyncEngine(api: html, store: store);
      await engine.enqueue(Command.create('c1', 'member.leave', {}));
      await engine.sync();
      expect(engine.last.state, isNot(SyncState.syncing));
      expect(await store.readOutbox(), hasLength(1));
      engine.dispose();
    },
  );

  test(
    'un envío demasiado grande (413) se parte; un comando mal formado (400) pasa a rechazados y no bloquea la cola',
    () async {
      final store = LocalStore(dir);
      final pushed = <int>[];
      final api = ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient((req) async {
          if (req.url.path == '/sync/pull') {
            return http.Response(jsonEncode({'clubs': {}, 'removed': []}), 200);
          }
          final cmds = (jsonDecode(req.body)['commands'] as List)
              .cast<Map<String, dynamic>>();
          pushed.add(cmds.length);
          if (cmds.length > 2) {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 'payload_too_large',
                  'message': 'Demasiado grande',
                },
              }),
              413,
            );
          }
          if (cmds.any((c) => c['type'] == 'roto')) {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 'invalid_input',
                  'message': 'Datos no válidos',
                },
              }),
              400,
            );
          }
          return http.Response(
            jsonEncode({
              'results': [
                for (final c in cmds) {'id': c['id'], 'status': 'applied'},
              ],
            }),
            200,
          );
        }),
      );
      final engine = SyncEngine(api: api, store: store);
      for (var i = 0; i < 4; i++) {
        await engine.enqueue(
          Command.create('c1', i == 1 ? 'roto' : 'member.leave', {}),
        );
      }
      await engine.sync();
      expect(await store.readOutbox(), isEmpty);
      expect((await store.readRejected()).single.command.type, 'roto');
      engine.dispose();
    },
  );

  test(
    'arrancar sin señal: /me sale de la copia guardada al instante; con un 5xx también',
    () async {
      final a = await controller();
      await a.login('kevin', 'secreto123');
      server.override = (_) => http.Response('fallo', 502);
      final b = await controller();
      final first = await b.watchMe().first;
      expect(first!.clubs.single.id, 'c1');
      expect(await b.loadMe(), isNotNull);
    },
  );

  test(
    'tras sincronizar se refresca /me: un servidor donde me expulsaron desaparece del selector',
    () async {
      final a = await controller();
      await a.login('kevin', 'secreto123');
      server.me = {..._me, 'clubs': []};
      server.pull = {
        'clubs': {},
        'removed': ['c1'],
      };
      await a.sync();
      expect(a.me!.clubs, isEmpty);
    },
  );

  test(
    'aceptar una invitación cuya respuesta se perdió: si ya estoy dentro, cuenta como éxito',
    () async {
      final a = await controller();
      server.me = {..._me, 'clubs': []};
      await a.login('kevin', 'secreto123');
      server.override = (req) {
        if (req.url.path.endsWith('/accept')) {
          server.me = _me; // el servidor sí me metió
          throw const SocketException('respuesta perdida');
        }
        return _pass;
      };
      await a.acceptInvite('ABCD-EFGH', clubId: 'c1');
      expect(a.me!.clubs.single.id, 'c1');
    },
  );

  test(
    'escrituras simultáneas del mismo archivo no se pisan ni fallan',
    () async {
      final store = LocalStore(dir);
      await Future.wait([
        for (var i = 0; i < 20; i++) store.writeMe({'n': i}),
      ]);
      expect((await store.readMe())!['n'], isA<int>());
    },
  );

  test('rechazos y descartes a la vez no se pierden', () async {
    final store = LocalStore(dir);
    final engine = SyncEngine(
      api: ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient((req) async {
          if (req.url.path == '/sync/pull') {
            return http.Response(jsonEncode({'clubs': {}, 'removed': []}), 200);
          }
          final cmds = (jsonDecode(req.body)['commands'] as List)
              .cast<Map<String, dynamic>>();
          return http.Response(
            jsonEncode({
              'results': [
                for (final c in cmds)
                  {
                    'id': c['id'],
                    'status': 'rejected',
                    'code': 'forbidden',
                    'message': 'No',
                  },
              ],
            }),
            200,
          );
        }),
      ),
      store: store,
    );
    final old = Command.create('c1', 'member.leave', {});
    await store.addRejected([
      RejectedChange(command: old, code: 'x', message: 'viejo'),
    ]);
    await engine.enqueue(
      Command.create('c1', 'member.ban', {'memberId': 'm2'}),
    );
    await Future.wait([engine.sync(), engine.dismissRejected(old.id)]);
    final rejected = await store.readRejected();
    expect(rejected.map((r) => r.command.type), ['member.ban']);
    engine.dispose();
  });
}
