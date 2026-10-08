import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/auth/session.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/state/providers.dart';
import 'package:elfurbo/cloud/ui/cloud_app.dart';
import 'package:elfurbo/ui/directory/directory_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settle_io.dart';

/// Un servidor de pruebas con un servidor público en el directorio (El Pre).
class _Server {
  final bodies = <String, Object?>{};
  bool joined = false;

  static const _user = {
    'id': 'u1',
    'username': 'kevincito',
    'displayName': 'Kevin',
    'isSuperadmin': false,
    'status': 'active',
  };

  Map<String, Object?> get _card => {
    'id': 'c9',
    'name': 'El Pre',
    'kind': 'group',
    'province': 'vcl',
    'city': 'Santa Clara',
    'color': 2,
    'official': false,
    'tier': 'verified',
    'members': 14,
    'playDays': [6, 7],
    'lastPlayedAt': '2026-10-04T14:00:00.000Z',
    'joinPolicy': 'request',
    'myStatus': joined ? 'pending' : 'none',
  };

  MockClient get client => MockClient((req) async {
    final key = '${req.method} ${req.url.path}';
    if (req.body.isNotEmpty) bodies[key] = jsonDecode(req.body);
    http.Response json(Object body, [int status = 200]) =>
        http.Response.bytes(utf8.encode(jsonEncode(body)), status);
    return switch (key) {
      'POST /auth/login' => json({'token': 'tok', 'user': _user}),
      'GET /me' => json({
        'user': _user,
        'clubs': [
          {
            'id': 'c1',
            'name': 'Unción y Fuego',
            'status': 'active',
            'memberId': 'm1',
            'role': 'player',
          },
        ],
        'clubRequests': [],
        'joinRequests': [
          if (joined)
            {
              'id': 'j1',
              'clubId': 'c9',
              'clubName': 'El Pre',
              'status': 'pending',
            },
        ],
      }),
      'POST /sync/pull' => json({'clubs': {}, 'removed': []}),
      'GET /directory' => json({
        'clubs': [_card],
        'next': null,
      }),
      'GET /directory/c9' => json({
        'club': {
          ..._card,
          'description': 'Los sábados en el Pre',
          'season': '2026',
          'topScorers': [
            {'name': 'Yoan', 'goals': 12, 'assists': 3, 'played': 8},
          ],
          'upcoming': [],
        },
      }),
      'POST /clubs/c9/join' => () {
        joined = true;
        return json({
          'status': 'pending',
          'request': {'id': 'j1'},
        }, 201);
      }(),
      _ => json({'results': []}),
    };
  });
}

void main() {
  late Directory dir;

  setUpAll(() => initializeDateFormatting('es'));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await dataDir('furbo-directory');
  });

  test('las etiquetas de los días de juego', () {
    expect(playDaysLabel([6, 7]), 'Juegan sáb y dom');
    expect(playDaysLabel([2]), 'Juegan mar');
    expect(playDaysLabel([1, 3, 5]), 'Juegan lun, mié y vie');
    expect(playDaysLabel([]), isNull);
  });

  testWidgets(
    'desde la hoja de servidores: buscar, ver el detalle y pedir entrar con un mensaje',
    (tester) async {
      final server = _Server();
      final cloud = await tester.runAsync(() async {
        final c = CloudController(
          api: ApiClient(baseUrl: 'https://api.test', client: server.client),
          sessions: SessionStore(await SharedPreferences.getInstance()),
          dataRoot: dir,
        );
        await c.login('kevincito', 'secreto123');
        await c.sync();
        return c;
      });
      await tester.runAsync(
        () => tester.pumpWidget(
          ProviderScope(
            overrides: [cloudProvider.overrideWithValue(cloud!)],
            child: const CloudApp(),
          ),
        ),
      );
      await settleIo(tester);

      await tester.tap(find.text('Unción y Fuego').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Buscar servidores'));
      await settleIo(tester, until: find.text('El Pre'));
      expect(find.text('Verificado'), findsOneWidget);
      expect(find.textContaining('Santa Clara, Villa Clara'), findsOneWidget);
      expect(
        find.textContaining('14 miembros · Juegan sáb y dom'),
        findsOneWidget,
      );

      await tester.tap(find.text('El Pre'));
      await settleIo(tester, until: find.text('Pedir entrar'));
      expect(find.text('Los sábados en el Pre'), findsOneWidget);
      expect(find.text('Goleadores · 2026'), findsOneWidget);

      await tester.tap(find.text('Pedir entrar'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Juego de lateral');
      await tester.runAsync(() => tester.tap(find.text('Pedir')));
      await settleIo(tester, until: find.text('Retirar la solicitud'));
      expect(server.bodies['POST /clubs/c9/join'], {
        'message': 'Juego de lateral',
      });
      expect(cloud!.me!.joinRequests.single.clubName, 'El Pre');
    },
  );
}
