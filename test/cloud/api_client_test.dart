import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/auth/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ApiClient', () {
    test('manda el token y el JSON, y devuelve el cuerpo', () async {
      late http.Request seen;
      final api = ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient((req) async {
          seen = req;
          return http.Response('{"ok":true}', 200);
        }),
      )..token = 'abc';
      final res = await api.post('/x', {'a': 1});
      expect(res, {'ok': true});
      expect(seen.url.toString(), 'https://api.test/x');
      expect(seen.headers['authorization'], 'Bearer abc');
      expect(jsonDecode(seen.body), {'a': 1});
    });

    test(
      'un error de la API trae código, mensaje en español y errores por campo',
      () async {
        final api = ApiClient(
          baseUrl: 'https://api.test',
          client: MockClient(
            (_) async => http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'error': {
                    'code': 'invalid_input',
                    'message': 'Datos no válidos',
                    'details': {
                      'username': ['Mínimo 3 caracteres'],
                    },
                  },
                }),
              ),
              400,
            ),
          ),
        );
        final e = await api
            .post('/x')
            .then<ApiException?>(
              (_) => null,
              onError: (Object e) => e as ApiException,
            );
        expect(e!.code, 'invalid_input');
        expect(e.message, 'Datos no válidos');
        expect(e.fieldErrors, {
          'username': ['Mínimo 3 caracteres'],
        });
      },
    );

    test('sin señal (socket o tiempo agotado) es OfflineException', () async {
      final api = ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient((_) async => throw const SocketException('sin red')),
      );
      expect(api.get('/x'), throwsA(isA<OfflineException>()));
      final slow = ApiClient(
        baseUrl: 'https://api.test',
        timeout: const Duration(milliseconds: 10),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.Response('{}', 200);
        }),
      );
      expect(slow.get('/x'), throwsA(isA<OfflineException>()));
    });

    test('un 500 sin JSON sigue siendo un ApiException legible', () async {
      final api = ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient((_) async => http.Response('boom', 502)),
      );
      expect(
        api.get('/x'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'http_502')),
      );
    });

    test('acentos y ñ llegan bien (UTF-8)', () async {
      final api = ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient(
          (_) async =>
              http.Response.bytes(utf8.encode('{"n":"Ñapa Ávila"}'), 200),
        ),
      );
      expect((await api.get('/x'))!['n'], 'Ñapa Ávila');
    });
  });

  group('SessionStore', () {
    test('guarda, lee y borra la sesión', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SessionStore(await SharedPreferences.getInstance());
      expect(store.read(), isNull);
      await store.write(
        const Session(
          token: 't',
          user: CloudUser(
            id: 'u1',
            username: 'kevin',
            displayName: 'Kevin',
            isSuperadmin: true,
          ),
        ),
      );
      final s = store.read()!;
      expect(s.token, 't');
      expect(s.user.username, 'kevin');
      expect(s.user.isSuperadmin, isTrue);
      await store.clear();
      expect(store.read(), isNull);
    });

    test('una sesión corrupta se trata como sin sesión', () async {
      SharedPreferences.setMockInitialValues({'cloud.session': '{roto'});
      final store = SessionStore(await SharedPreferences.getInstance());
      expect(store.read(), isNull);
    });
  });

  group('AuthApi', () {
    test('login devuelve la sesión', () async {
      final api = ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient(
          (req) async => http.Response(
            jsonEncode({
              'token': 'tok',
              'user': {
                'id': 'u1',
                'username': 'kevin',
                'displayName': 'Kevin',
                'isSuperadmin': false,
                'status': 'active',
              },
            }),
            200,
          ),
        ),
      );
      final s = await AuthApi(api).login('kevin', 'secreto123');
      expect(s.token, 'tok');
      expect(s.user.displayName, 'Kevin');
    });
  });
}
