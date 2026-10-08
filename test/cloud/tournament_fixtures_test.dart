import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/auth/session.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/state/providers.dart';
import 'package:elfurbo/cloud/sync/club_data.dart';
import 'package:elfurbo/cloud/sync/command.dart';
import 'package:elfurbo/cloud/sync/reducers.dart';
import 'package:elfurbo/cloud/ui/cloud_app.dart';
import 'package:elfurbo/ui/tournament/fixture_detail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  'isSuperadmin': false,
  'status': 'active',
};

Map<String, Object?> team(String id, String name) => {
  'id': id,
  'name': name,
  'shortName': name.substring(0, 3).toUpperCase(),
  'color': 1,
  'status': 'approved',
};

Map<String, Object?> player(String team, String member) => {
  'id': '$team:$member',
  'teamId': team,
  'memberId': member,
  'status': 'active',
};

Map<String, Object?> member(String id, String name, [String? userId]) => {
  'id': id,
  'userId': userId,
  'role': userId == null ? 'guest' : 'owner',
  'status': 'active',
  'displayName': name,
};

Map<String, Object?> _pull() => {
  'clubs': {
    't1': {
      'cursor': 3,
      'hasMore': false,
      'snapshot': true,
      'upserts': {
        'club': [
          {
            'id': 't1',
            'name': 'Copa Verano',
            'status': 'active',
            'kind': 'tournament',
            'settings': {},
          },
        ],
        'member': [
          member('m1', 'Kevin', 'u1'),
          member('a1', 'Ana'),
          member('b1', 'Beto'),
        ],
        'tournament': [
          {
            'id': 't1',
            'format': 'league',
            'status': 'in_progress',
            'rules': {},
          },
        ],
        'team': [team('ta', 'Águilas'), team('tb', 'Búhos')],
        'teamPlayer': [player('ta', 'a1'), player('tb', 'b1')],
        'fixture': [
          {
            'id': 'f1',
            'stage': 'league',
            'round': 1,
            'homeTeamId': 'ta',
            'awayTeamId': 'tb',
            'status': 'scheduled',
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
    dir = await dataDir('furbo-fixtures');
  });

  test(
    'reductores: el ganador de una semi pasa a la final y vuelve a salir al borrar el resultado',
    () {
      final server = ClubData(clubId: 't1')
        ..table('fixture')['s1'] = {
          'id': 's1',
          'stage': 'knockout',
          'round': 1,
          'homeTeamId': 'A',
          'awayTeamId': 'B',
          'status': 'scheduled',
        }
        ..table('fixture')['fin'] = {
          'id': 'fin',
          'stage': 'knockout',
          'round': 2,
          'homeSource': {'winnerOf': 's1'},
          'awaySource': {'group': 'B', 'pos': 1},
          'status': 'scheduled',
        };
      final played = clubView(server, [
        Command.create('t1', 'fixture.result', {
          'fixtureId': 's1',
          'homeScore': 0,
          'awayScore': 0,
          'homePens': 2,
          'awayPens': 4,
          'events': [],
          'lineups': {
            'home': ['a'],
            'away': ['b'],
          },
        }),
      ], myMemberId: 'm1');
      expect(played.one('fixture', 'fin')!['homeTeamId'], 'B');
      expect(played.all('fixtureLineup'), hasLength(2));
      final reset = clubView(played, [
        Command.create('t1', 'fixture.setStatus', {
          'fixtureId': 's1',
          'status': 'scheduled',
        }),
      ], myMemberId: 'm1');
      expect(reset.one('fixture', 'fin')!['homeTeamId'], isNull);
      expect(reset.all('fixtureLineup'), isEmpty);
    },
  );

  testWidgets(
    'poner un resultado desde el partido: se ve al momento y entra en la tabla',
    (tester) async {
      final pushed = <Object?>[];
      final client = MockClient((req) async {
        http.Response json(Object body) =>
            http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        return switch ('${req.method} ${req.url.path}') {
          'POST /auth/login' => json({'token': 'tok', 'user': _user}),
          'GET /me' => json({
            'user': _user,
            'clubs': [
              {
                'id': 't1',
                'name': 'Copa Verano',
                'status': 'active',
                'kind': 'tournament',
                'memberId': 'm1',
                'role': 'owner',
              },
            ],
            'clubRequests': [],
          }),
          'POST /sync/pull' => json(_pull()),
          'POST /sync/push' => () {
            pushed.add(jsonDecode(req.body));
            return json({'results': []});
          }(),
          _ => json({}),
        };
      });
      final cloud = await tester.runAsync(() async {
        final c = CloudController(
          api: ApiClient(baseUrl: 'https://api.test', client: client),
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
      expect(find.text('Jornada 1'), findsOneWidget);
      await tester.tap(find.text('Águilas').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Poner resultado'));
      await tester.pumpAndSettle();
      // 1-0 para Águilas.
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Guardar')));
      await settleIo(tester, until: find.text('1 - 0'));
      expect(find.text('1 - 0'), findsOneWidget);

      // Volver al calendario: la pantalla de abajo se reanuda con el resultado
      // (con riverpod 3.3.2 tal cual saltaba una aserción; ver
      // third_party/riverpod/LEEME.md).
      Navigator.of(tester.element(find.text('1 - 0'))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(FixtureDetailScreen), findsNothing);
      expect(find.text('1 - 0'), findsOneWidget, reason: 'en el calendario');

      await tester.tap(find.text('Tabla'));
      await tester.pumpAndSettle();
      final cells = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(Table),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .toList();
      // Cabecera y una fila por equipo: #, equipo, PJ, G, E, P, DG, Pts.
      expect(cells.sublist(8), [
        ...['1', 'Águilas', '1', '1', '0', '0', '+1', '3'],
        ...['2', 'Búhos', '1', '0', '0', '1', '-1', '0'],
      ]);
    },
  );
}
