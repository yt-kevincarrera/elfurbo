import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/admin_api.dart';
import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/auth/session.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/state/providers.dart';
import 'package:elfurbo/cloud/ui/cloud_app.dart';
import 'package:elfurbo/models/app_user.dart';
import 'package:elfurbo/ui/admin/audit_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settle_io.dart';

/// Un servidor de pruebas para el admin y el superadmin: guarda lo que le llega.
class _Server {
  _Server(this.role);

  final String role;
  final requests = <String>[];
  final bodies = <String, Object?>{};

  Map<String, Object?> get _user => {
    'id': 'u1',
    'username': 'kevincito',
    'displayName': 'Kevin',
    'isSuperadmin': true,
    'status': 'active',
  };

  MockClient get client => MockClient((req) async {
    final key = '${req.method} ${req.url.path}';
    requests.add(key);
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
            'role': role,
          },
        ],
        'clubRequests': [],
      }),
      'POST /sync/pull' => json({
        'clubs': {
          'c1': {
            'cursor': 1,
            'hasMore': false,
            'snapshot': true,
            'upserts': {
              'member': [
                {
                  'id': 'm1',
                  'userId': 'u1',
                  'role': role,
                  'status': 'active',
                  'displayName': 'Kevin',
                },
              ],
            },
            'deletes': {},
          },
        },
        'removed': [],
      }),
      'GET /clubs/c1/invites' => json({
        'invites': [
          {
            'code': 'ABCD-EFGH',
            'role': 'player',
            'maxUses': 10,
            'uses': 3,
            'expiresAt': '2030-01-01T00:00:00.000Z',
            'targetMemberId': null,
          },
        ],
      }),
      'POST /clubs/c1/invites' => json({
        'invite': {
          'code': 'WXYZ-2345',
          'role': 'scorer',
          'maxUses': 1,
          'uses': 0,
          'expiresAt': '2030-01-01T00:00:00.000Z',
          'targetMemberId': null,
        },
      }, 201),
      'GET /admin/clubs' => json({
        'clubs': [
          if (!requests.contains('POST /admin/clubs/c9/approve'))
            {
              'id': 'c9',
              'name': 'Los del Vedado',
              'status': 'pending',
              'requestNote': 'Jugamos los jueves',
              'createdAt': '2026-10-04T10:00:00.000Z',
              'ownerUsername': 'yoandry',
              'members': 0,
            },
        ],
      }),
      'POST /admin/clubs/c9/approve' => json({
        'club': {'id': 'c9', 'status': 'active'},
      }),
      _ => json({'results': []}),
    };
  });
}

void main() {
  late Directory dir;

  setUpAll(() => initializeDateFormatting('es'));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await dataDir('furbo-admin');
  });

  Future<CloudController> start(WidgetTester tester, _Server server) async {
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
    // Dentro de runAsync: el sync que arranca al abrir corre con el reloj de verdad.
    await tester.runAsync(
      () => tester.pumpWidget(
        ProviderScope(
          overrides: [cloudProvider.overrideWithValue(cloud!)],
          child: const CloudApp(),
        ),
      ),
    );
    await settleIo(tester);
    return cloud!;
  }

  testWidgets(
    'admin: ve las invitaciones del servidor y crea una con el rol elegido',
    (tester) async {
      final server = _Server('owner');
      await start(tester, server);
      await tester.tap(find.text('Admin'));
      await settleIo(tester, until: find.text('ABCD-EFGH'));
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      expect(find.textContaining('3 de 10'), findsOneWidget);
      expect(find.text('Ajustes del servidor'), findsOneWidget);

      await tester.tap(find.text('Invitar'));
      await settleIo(tester);
      await tester.tap(find.text('Anotador'));
      await settleIo(tester);
      await tester.tap(find.text('Crear y compartir'));
      await settleIo(tester);
      expect(server.bodies['POST /clubs/c1/invites'], {
        'role': 'scorer',
        'maxUses': 1,
        'expiresInDays': 7,
      });
    },
  );

  testWidgets(
    'superadmin: aprueba una solicitud desde su panel y la lista se vacía',
    (tester) async {
      final server = _Server('owner');
      await start(tester, server);
      await tester.tap(find.byTooltip('Servidores y cuenta'));
      await settleIo(tester);
      await tester.tap(find.text('Panel de superadmin'));
      await settleIo(tester, until: find.text('Los del Vedado'));
      expect(find.text('Los del Vedado'), findsOneWidget);
      await tester.tap(find.text('Aprobar'));
      await settleIo(tester, until: find.text('Nadie esperando'));
      expect(server.requests, contains('POST /admin/clubs/c9/approve'));
      expect(find.text('Nadie esperando'), findsOneWidget);
    },
  );

  testWidgets('el dueño no ve "Salir de este servidor"; un jugador sí', (
    tester,
  ) async {
    await start(tester, _Server('owner'));
    await tester.tap(find.byTooltip('Servidores y cuenta'));
    await settleIo(tester);
    expect(find.text('Salir de este servidor'), findsNothing);
  });

  testWidgets('un jugador puede salir del servidor', (tester) async {
    await start(tester, _Server('player'));
    await tester.tap(find.byTooltip('Servidores y cuenta'));
    await settleIo(tester);
    expect(find.text('Salir de este servidor'), findsOneWidget);
    expect(find.text('Admin'), findsNothing);
  });

  test('la auditoría se cuenta en claro', () {
    const raul = AppUser(
      uid: 'm2',
      displayName: 'Raúl',
      role: UserRole.player,
      status: UserStatus.active,
    );
    AuditEntry entry(String action, String key, [Map<String, dynamic>? s]) =>
        AuditEntry(
          id: 1,
          action: action,
          entity: 'x',
          entityKey: key,
          summary: s ?? const {},
          at: DateTime(2026, 10, 5),
        );
    final users = {'m2': raul};
    expect(describeAudit(entry('member.ban', 'm2'), users), 'expulsó a Raúl');
    expect(
      describeAudit(
        entry('report.decide', 'md1:m2', {'decision': 'rejected'}),
        users,
      ),
      'rechazó el reporte de Raúl',
    );
    expect(
      describeAudit(entry('member.setRole', 'm2', {'to': 'scorer'}), users),
      'hizo anotador a Raúl',
    );
    expect(describeAudit(entry('algo.nuevo', 'k'), users), 'hizo "algo.nuevo"');
  });
}
