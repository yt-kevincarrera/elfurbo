import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/auth/session.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/state/providers.dart';
import 'package:elfurbo/cloud/ui/cloud_app.dart';
import 'package:elfurbo/data/update_controller.dart';
import 'package:elfurbo/ui/matches/match_detail_screen.dart';
import 'package:elfurbo/domain/app_update.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settle_io.dart';

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
    dir = await dataDir('furbo-shell');
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

  Future<void> pump(
    WidgetTester tester,
    CloudController cloud, {
    List<Override> overrides = const [],
  }) async {
    // Dentro de runAsync: el sync que arranca al abrir corre con el reloj de verdad.
    await tester.runAsync(
      () => tester.pumpWidget(
        ProviderScope(
          overrides: [cloudProvider.overrideWithValue(cloud), ...overrides],
          child: const CloudApp(),
        ),
      ),
    );
    await settleIo(tester);
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

  testWidgets(
    'la hoja de servidores lleva a la agenda de todos, y desde ahí se dice "Voy"',
    (tester) async {
      final cloud = await tester.runAsync(() => loggedIn('player'));
      await pump(tester, cloud!);
      await tester.tap(find.text('Unción y Fuego').first);
      await tester.pumpAndSettle();
      expect(find.text('Tus servidores'), findsOneWidget);
      expect(find.text('1 jornada en los próximos 14 días'), findsOneWidget);
      expect(find.text('Unirme con un código'), findsOneWidget);

      await tester.tap(find.text('Agenda de todos'));
      await tester.pumpAndSettle();
      expect(find.textContaining('El Pre'), findsOneWidget);
      ChoiceChip chip(String label) =>
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));
      expect(chip('Voy').selected, isFalse);
      await tester.runAsync(() => tester.tap(find.text('Voy')));
      await settleIo(tester, until: find.textContaining('1 va'));
      expect(
        chip('Voy').selected,
        isTrue,
        reason: 'el cambio se ve al momento',
      );
      expect(find.textContaining('1 va'), findsOneWidget);
    },
  );

  testWidgets(
    'decir "Voy" en el detalle de la jornada y volver: la lista ya lo cuenta',
    (tester) async {
      final cloud = await tester.runAsync(() => loggedIn('player'));
      await pump(tester, cloud!);
      await tester.tap(find.textContaining('El Pre').first);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Voy')));
      await settleIo(
        tester,
        until: find.byWidgetPredicate(
          (w) => w is SegmentedButton && w.selected.isNotEmpty,
        ),
      );

      // La lista se reanuda con el cambio (con riverpod 3.3.2 tal cual
      // saltaba una aserción; ver third_party/riverpod/LEEME.md).
      Navigator.of(tester.element(find.text('Voy'))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(MatchDetailScreen), findsNothing);
      expect(find.textContaining('1 van'), findsOneWidget);
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
      await tester.runAsync(() => tester.tap(find.text('Cerrar sesión').last));
      await settleIo(tester, until: find.text('Entrar'));
      expect(cloud.session, isNull);
      expect(find.text('Entrar'), findsOneWidget);
      expect(find.text('Cerrando sesión…'), findsNothing);
    },
  );

  testWidgets(
    'con una versión nueva: botón en la barra y punto en Perfil, sin entrar al menú',
    (tester) async {
      final cloud = await tester.runAsync(() => loggedIn('player'));
      await pump(
        tester,
        cloud!,
        overrides: [updateProvider.overrideWith(_PendingUpdate.new)],
      );
      expect(find.byTooltip('Hay una versión nueva'), findsOneWidget);
      final perfil = find.ancestor(
        of: find.text('Perfil'),
        matching: find.byType(NavigationDestination),
      );
      final dot = find.descendant(of: perfil, matching: find.byType(Badge));
      expect(
        tester.widgetList<Badge>(dot).any((b) => b.isLabelVisible),
        isTrue,
      );
    },
  );
}

/// Una versión nueva ya conocida (y que no pregunta a nadie).
class _PendingUpdate extends UpdateController {
  @override
  UpdateState build() => const UpdateState(
    phase: UpdatePhase.available,
    release: AppRelease(tag: 'v9.0.0', title: '', notes: '', assets: []),
  );

  @override
  Future<void> check({bool force = false}) async {}
}
