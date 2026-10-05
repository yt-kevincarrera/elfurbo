import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/auth/session.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/state/providers.dart';
import 'package:elfurbo/cloud/ui/cloud_app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = {
  'id': 'u1',
  'username': 'kevincito',
  'displayName': 'Kevin',
  'isSuperadmin': true,
  'status': 'active',
};

Map<String, Object?> _me(String role) => {
  'user': _user,
  'clubs': [
    {
      'id': 'c1',
      'name': 'Unción y Fuego',
      'status': 'active',
      'memberId': 'm1',
      'role': role,
    },
  ],
  'clubRequests': [],
};

final _startsAt = DateTime.now().add(const Duration(days: 2)).toUtc();

final _pull = {
  'clubs': {
    'c1': {
      'cursor': 5,
      'hasMore': false,
      'snapshot': true,
      'upserts': {
        'club': [
          {
            'id': 'c1',
            'name': 'Unción y Fuego',
            'description': '',
            'status': 'active',
            'settings': {
              'matchdayCreators': 'members',
              'reportValidation': 'confirm',
              'confirmationsNeeded': 2,
              'closeAfterHours': 72,
              'timezone': 'America/Havana',
            },
          },
        ],
        'member': [
          {
            'id': 'm1',
            'userId': 'u1',
            'role': 'owner',
            'status': 'active',
            'displayName': 'Kevin',
            'nickname': null,
            'claimedAt': null,
          },
        ],
        'season': [
          {
            'id': 's1',
            'name': '2026',
            'startDate': '2026-01-01',
            'isActive': true,
            'isClosed': false,
          },
        ],
        'matchday': [
          {
            'id': 'md1',
            'seasonId': 's1',
            'startsAt': _startsAt.toIso8601String(),
            'durationMinutes': 120,
            'place': 'El Pre',
            'notes': null,
            'status': 'scheduled',
            'teams': null,
            'createdBy': 'm1',
          },
        ],
      },
      'deletes': {},
    },
  },
  'removed': [],
};

void main() {
  late Directory dir;

  setUpAll(() => initializeDateFormatting('es'));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('furbo-shell');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Alguna escritura del sync de fondo todavía en vuelo.
    }
  });

  Future<CloudController> loggedIn(String role) async {
    final prefs = await SharedPreferences.getInstance();
    final c = CloudController(
      api: ApiClient(
        baseUrl: 'https://api.test',
        client: MockClient(
          (req) async => switch (req.url.path) {
            '/auth/login' => http.Response(
              jsonEncode({'token': 'tok', 'user': _user}),
              200,
            ),
            '/me' => http.Response.bytes(
              utf8.encode(jsonEncode(_me(role))),
              200,
            ),
            '/sync/pull' => http.Response.bytes(
              utf8.encode(jsonEncode(_pull)),
              200,
            ),
            _ => http.Response('{"results":[]}', 200),
          },
        ),
      ),
      sessions: SessionStore(prefs),
      dataRoot: dir,
    );
    await c.login('kevincito', 'secreto123');
    await c.sync();
    return c;
  }

  Future<void> pump(WidgetTester tester, CloudController cloud) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [cloudProvider.overrideWithValue(cloud)],
          child: const CloudApp(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
  }

  testWidgets(
    'con servidor: barra del servidor, la jornada que llegó del pull y crear jornada',
    (tester) async {
      final cloud = await tester.runAsync(() => loggedIn('owner'));
      await pump(tester, cloud!);
      expect(find.text('Unción y Fuego'), findsOneWidget);
      expect(find.text('Jornadas'), findsWidgets);
      expect(find.textContaining('El Pre'), findsOneWidget);
      expect(find.text('Nueva jornada'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget, reason: 'el owner lo ve');
    },
  );

  testWidgets('un jugador no ve la pestaña Admin pero sí crea jornadas', (
    tester,
  ) async {
    final cloud = await tester.runAsync(() => loggedIn('player'));
    await pump(tester, cloud!);
    expect(find.text('Nueva jornada'), findsOneWidget);
    expect(find.text('Admin'), findsNothing);
  });

  testWidgets(
    'cerrar sesión desde la barra: vuelve a la bienvenida sin dejar el diálogo de "Cerrando sesión…"',
    (tester) async {
      final cloud = await tester.runAsync(() => loggedIn('owner'));
      await pump(tester, cloud!);
      await tester.tap(find.byTooltip('Servidores y cuenta'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Cerrar sesión').last);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      expect(cloud.session, isNull);
      expect(find.text('Entrar'), findsOneWidget);
      expect(find.text('Cerrando sesión…'), findsNothing);
    },
  );
}
