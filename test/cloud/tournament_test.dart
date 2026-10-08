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
import 'package:elfurbo/models/tournament.dart';
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
            'color': 4,
            'settings': {},
          },
        ],
        'member': [
          {
            'id': 'm1',
            'userId': 'u1',
            'role': 'player',
            'status': 'active',
            'displayName': 'Kevin',
          },
          {
            'id': 'm2',
            'userId': 'u2',
            'role': 'owner',
            'status': 'active',
            'displayName': 'Yoan',
          },
        ],
        'tournament': [
          {
            'id': 't1',
            'format': 'league',
            'status': 'registration',
            'rules': {'pointsWin': 3},
            'maxTeams': 8,
            'minPlayers': 5,
            'maxPlayers': 12,
          },
        ],
        'team': [
          {
            'id': 'tm1',
            'name': 'Los Tigres',
            'shortName': 'TIG',
            'color': 1,
            'captainMemberId': 'm2',
            'status': 'approved',
          },
        ],
        'teamPlayer': [
          {
            'id': 'tm1:m2',
            'teamId': 'tm1',
            'memberId': 'm2',
            'shirt': 10,
            'status': 'active',
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
    dir = await dataDir('furbo-tournament');
  });

  test('reductores: inscribir, aprobar, plantilla y retirar', () {
    final server = ClubData(clubId: 't1')
      ..table('member')['o'] = {'id': 'o', 'role': 'owner'}
      ..table('member')['p'] = {'id': 'p', 'role': 'player'}
      ..table('tournament')['t1'] = {
        'id': 't1',
        'status': 'draft',
        'rules': {'pointsWin': 3, 'legs': 1},
      };
    // Un jugador inscribe el suyo: pendiente y él de capitán.
    var view = clubView(server, [
      Command.create('t1', 'team.create', {
        'id': 'a',
        'name': 'Tigres',
        'shortName': 'TIG',
        'color': 1,
      }),
    ], myMemberId: 'p');
    expect(view.one('team', 'a'), containsPair('status', 'pending'));
    expect(view.one('team', 'a'), containsPair('captainMemberId', 'p'));
    expect(view.one('teamPlayer', 'a:p'), containsPair('status', 'active'));

    // El organizador: reglas mezcladas, aprueba, mete a alguien y lo retira.
    view = clubView(view, [
      Command.create('t1', 'tournament.update', {
        'rules': {'legs': 2},
        'status': 'registration',
      }),
      Command.create('t1', 'team.setStatus', {
        'teamId': 'a',
        'status': 'approved',
      }),
      Command.create('t1', 'team.addPlayer', {
        'teamId': 'a',
        'memberId': 'o',
        'shirt': 9,
      }),
    ], myMemberId: 'o');
    final t = Tournament.fromCloud(view.one('tournament', 't1')!);
    expect(t.status, TournamentStatus.registration);
    expect(t.rules.legs, 2);
    expect(t.rules.pointsWin, 3);
    expect(view.one('team', 'a')!['status'], 'approved');
    expect(view.one('teamPlayer', 'a:o')!['shirt'], 9);

    view = clubView(view, [
      Command.create('t1', 'team.setStatus', {
        'teamId': 'a',
        'status': 'withdrawn',
      }),
    ], myMemberId: 'o');
    expect(view.all('teamPlayer').map((p) => p['status']).toSet(), {'removed'});
  });

  testWidgets(
    'un torneo tiene sus pestañas; inscribir mi equipo sin señal y verlo pendiente',
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
                'role': 'player',
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
      expect(find.text('Partidos'), findsWidgets);
      expect(find.text('Todavía no hay calendario'), findsOneWidget);
      expect(find.text('Admin'), findsNothing);

      await tester.tap(find.text('Equipos'));
      await tester.pumpAndSettle();
      expect(find.text('Los Tigres'), findsOneWidget);
      expect(find.textContaining('1 de 8 equipos'), findsOneWidget);

      await tester.tap(find.text('Inscribir mi equipo'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'Leones');
      await tester.enterText(find.byType(TextFormField).at(1), 'leo');
      await tester.runAsync(() => tester.tap(find.text('Guardar')));
      await settleIo(tester, until: find.text('Plantilla'));
      expect(find.text('Leones'), findsWidgets);
      expect(find.textContaining('Pendiente'), findsOneWidget);
      expect(find.text('Capitán · Tú'), findsOneWidget);
    },
  );
}
