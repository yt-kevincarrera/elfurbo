import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/auth/session.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
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

void main() {
  late Directory dir;
  late List<String> calls;
  bool offline = false;
  int status401For = -1;

  Future<CloudController> controller() async {
    final prefs = await SharedPreferences.getInstance();
    final client = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (offline) throw const SocketException('sin red');
      if (status401For == calls.length) {
        return http.Response(
          jsonEncode({
            'error': {'code': 'session_expired', 'message': 'Tu sesión caducó'},
          }),
          401,
        );
      }
      return switch (req.url.path) {
        '/auth/login' || '/auth/register' => http.Response(
          jsonEncode({'token': 'tok', 'user': _user}),
          200,
        ),
        '/auth/logout' => http.Response('', 204),
        '/me' => http.Response(jsonEncode(_me), 200),
        '/invites/ABCD-EFGH' => http.Response(
          jsonEncode({
            'club': {'id': 'c2', 'name': 'Otro', 'description': ''},
            'role': 'player',
            'claim': {'displayName': 'Yoandry'},
          }),
          200,
        ),
        '/invites/ABCD-EFGH/accept' => http.Response('{}', 201),
        '/sync/push' => http.Response(
          jsonEncode({
            'results': [
              for (final c in (jsonDecode(req.body)['commands'] as List))
                {'id': c['id'], 'status': 'applied'},
            ],
          }),
          200,
        ),
        '/sync/pull' => http.Response(
          jsonEncode({'clubs': {}, 'removed': []}),
          200,
        ),
        _ => http.Response('{}', 404),
      };
    });
    return CloudController(
      api: ApiClient(baseUrl: 'https://api.test', client: client),
      sessions: SessionStore(prefs),
      dataRoot: dir,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('furbo-ctrl');
    calls = [];
    offline = false;
    status401For = -1;
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
    'entrar guarda la sesión, trae /me y la sesión sobrevive a reabrir la app',
    () async {
      final a = await controller();
      await a.login('kevin', 'secreto123');
      expect(a.session!.user.username, 'kevin');
      expect(a.me!.clubs.single.name, 'Pachanga');
      final b = await controller(); // reabrir la app
      expect(b.session!.token, 'tok');
      expect(b.engine, isNotNull);
    },
  );

  test('sin señal, /me sale de la última copia guardada', () async {
    final a = await controller();
    await a.login('kevin', 'secreto123');
    offline = true;
    final b = await controller();
    final me = await b.loadMe();
    expect(me!.clubs.single.id, 'c1');
  });

  test(
    'un cambio hecho sin señal se ve en la vista y espera en la cola',
    () async {
      final a = await controller();
      await a.login('kevin', 'secreto123');
      offline = true;
      await a.run('c1', 'member.createGuest', {
        'id': 'g1',
        'displayName': 'Yoandry',
      });
      final view = await a.view('c1');
      expect(view.one('member', 'g1')!['displayName'], 'Yoandry');
      expect(await a.engine!.pending(), hasLength(1));
    },
  );

  test(
    'salir borra los datos de la cuenta en el teléfono (aunque no haya señal)',
    () async {
      final a = await controller();
      await a.login('kevin', 'secreto123');
      await a.run('c1', 'member.leave', {});
      offline = true;
      await a.logout();
      expect(a.session, isNull);
      expect(dir.listSync(), isEmpty);
      final b = await controller();
      expect(b.session, isNull);
    },
  );

  test('si el servidor dice que la sesión caducó, se sale solo', () async {
    final a = await controller();
    await a.login('kevin', 'secreto123');
    await a.sync(); // Deja terminar el sync que lanza el login.
    await a.run('c1', 'member.leave', {});
    status401For = calls.length + 1;
    await a.sync();
    expect(a.session, isNull);
  });

  test('vista previa y aceptar una invitación', () async {
    final a = await controller();
    await a.login('kevin', 'secreto123');
    final p = await a.previewInvite(' ABCD-EFGH ');
    expect(p.clubName, 'Otro');
    expect(p.claimName, 'Yoandry');
    calls.clear();
    await a.acceptInvite('ABCD-EFGH');
    expect(
      calls,
      containsAllInOrder([
        'POST /invites/ABCD-EFGH/accept',
        'GET /me',
        'POST /sync/pull',
      ]),
    );
  });

  test('dos cuentas en el mismo teléfono no comparten datos', () async {
    final a = await controller();
    await a.login('kevin', 'secreto123');
    expect(
      dir.listSync().map(
        (e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ),
      contains('u-u1'),
    );
  });
}
