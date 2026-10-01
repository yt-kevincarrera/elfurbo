import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/auth/session.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/state/providers.dart';
import 'package:elfurbo/cloud/sync/command.dart';
import 'package:elfurbo/cloud/sync/sync_engine.dart';
import 'package:elfurbo/cloud/ui/cloud_app.dart';
import 'package:elfurbo/cloud/ui/home_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = {
  'id': 'u1',
  'username': 'kevin',
  'displayName': 'Kevin',
  'isSuperadmin': false,
  'status': 'active',
};

Future<CloudController> _controller(
  Directory dir, {
  bool badPassword = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final client = MockClient((req) async {
    return switch (req.url.path) {
      '/auth/login' when badPassword => http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'error': {
              'code': 'invalid_credentials',
              'message': 'Usuario o contraseña incorrectos',
            },
          }),
        ),
        401,
      ),
      '/auth/login' => http.Response(
        jsonEncode({'token': 'tok', 'user': _user}),
        200,
      ),
      '/me' => http.Response(
        jsonEncode({'user': _user, 'clubs': [], 'clubRequests': []}),
        200,
      ),
      '/sync/pull' => http.Response(
        jsonEncode({'clubs': {}, 'removed': []}),
        200,
      ),
      _ => http.Response('{}', 200),
    };
  });
  return CloudController(
    api: ApiClient(baseUrl: 'https://api.test', client: client),
    sessions: SessionStore(prefs),
    dataRoot: dir,
  );
}

void main() {
  late Directory dir;

  setUpAll(() => initializeDateFormatting('es'));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('furbo-ui');
  });
  tearDown(() async {
    // Puede quedar alguna escritura en vuelo del sync de fondo: no hace fallar el test.
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Ya no existe o la está usando otra operación que termina enseguida.
    }
  });

  Future<void> pumpApp(WidgetTester tester, CloudController cloud) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudProvider.overrideWithValue(cloud)],
        child: const CloudApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sin sesión: bienvenida con entrar, crear cuenta y código', (
    tester,
  ) async {
    final cloud = await tester.runAsync(() => _controller(dir));
    await pumpApp(tester, cloud!);
    expect(find.text('Entrar'), findsOneWidget);
    expect(find.text('Crear cuenta'), findsOneWidget);
    expect(find.text('Tengo un código de invitación'), findsOneWidget);
  });

  testWidgets('entrar con la contraseña mal enseña el mensaje del servidor', (
    tester,
  ) async {
    final cloud = await tester.runAsync(
      () => _controller(dir, badPassword: true),
    );
    await pumpApp(tester, cloud!);
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Usuario'), 'kevin');
    await tester.enterText(
      find.widgetWithText(TextField, 'Contraseña'),
      'mala',
    );
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Entrar'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('Usuario o contraseña incorrectos'), findsOneWidget);
  });

  testWidgets('con sesión y sin servidores: cómo unirse o pedir uno', (
    tester,
  ) async {
    final cloud = await tester.runAsync(() async {
      final c = await _controller(dir);
      await c.login('kevin', 'secreto123');
      return c;
    });
    await tester.runAsync(() async {
      await pumpApp(tester, cloud!);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('Unirme con un código'), findsOneWidget);
    expect(find.text('Solicitar un servidor'), findsOneWidget);
    expect(find.textContaining('Hola, Kevin'), findsOneWidget);
  });

  testWidgets(
    'primera vez sin señal: "sin conexión" con reintentar, no "no estás en ningún servidor"',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'cloud.session': jsonEncode({'token': 'tok', 'user': _user}),
      });
      final cloud = await tester.runAsync(() async {
        final prefs = await SharedPreferences.getInstance();
        return CloudController(
          api: ApiClient(
            baseUrl: 'https://api.test',
            client: MockClient(
              (_) async => throw const SocketException('sin red'),
            ),
          ),
          sessions: SessionStore(prefs),
          dataRoot: dir,
        );
      });
      // Sin pumpAndSettle: el spinner de "cargando" gira mientras se lee del disco.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [cloudProvider.overrideWithValue(cloud!)],
            child: const CloudApp(),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      await tester.pump();
      expect(find.textContaining('Sin conexión'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.textContaining('ningún servidor'), findsNothing);
    },
  );

  testWidgets('salir con cambios sin enviar pide confirmación', (tester) async {
    final cloud = await tester.runAsync(() async {
      final c = await _controller(dir);
      await c.login('kevin', 'secreto123');
      await c.engine!.enqueue(Command.create('c1', 'member.leave', {}));
      return c;
    });
    await tester.runAsync(() async {
      await pumpApp(tester, cloud!);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Cerrar sesión'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('¿Salir igual?'), findsOneWidget);
    expect(find.textContaining('1 cambio sin enviar'), findsOneWidget);
    expect(cloud!.session, isNotNull);
  });

  test('etiquetas del indicador de sync', () {
    final at = DateTime(2026, 10, 4, 14, 32);
    expect(syncLabel(const SyncStatus(state: SyncState.idle)), 'Todo al día');
    expect(
      syncLabel(const SyncStatus(state: SyncState.idle, pending: 3)),
      '3 cambios por enviar',
    );
    expect(
      syncLabel(const SyncStatus(state: SyncState.idle, pending: 1)),
      '1 cambio por enviar',
    );
    expect(
      syncLabel(SyncStatus(state: SyncState.offline, lastSync: at)),
      'Sin conexión · último sync 14:32',
    );
  });
}
