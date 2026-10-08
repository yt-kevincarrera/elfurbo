import 'dart:convert';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/api/players_api.dart';
import 'package:elfurbo/cloud/state/providers.dart';
import 'package:elfurbo/ui/profile/global_stats.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';

Map<String, Object?> profileJson({bool showPrivate = true}) => {
  'user': {
    'id': 'u1',
    'username': 'yoan',
    'displayName': 'Yoan',
    'since': '2026-01-10T00:00:00.000Z',
  },
  'memberships': [
    {
      'clubId': 'c1',
      'name': 'Los Pinos',
      'kind': 'group',
      'visibility': 'public',
      'official': false,
      'tier': 'verified',
      'color': 3,
      'role': 'player',
      'periods': [
        {
          'periodId': 's1',
          'name': 'Otoño',
          'tier': 'verified',
          'frozen': true,
          'played': 10,
          'goals': 8,
          'assists': 2,
          'mvps': 1,
          'hatTricks': 1,
          'flag': false,
        },
      ],
      'totals': {'played': 10, 'goals': 8, 'assists': 2, 'mvps': 1},
    },
    {
      'clubId': null,
      'name': null,
      'kind': 'group',
      'visibility': 'private',
      'official': false,
      'tier': 'casual',
      'color': 0,
      'role': 'player',
      'periods': [
        {
          'periodId': 's9',
          'name': '2026',
          'tier': 'casual',
          'frozen': false,
          'played': 3,
          'goals': 14,
          'assists': 0,
          'mvps': 0,
          'hatTricks': 3,
          'flag': true,
        },
      ],
      'totals': {'played': 3, 'goals': 14, 'assists': 0, 'mvps': 0},
    },
  ],
  'totals': {
    'all': {'played': 13, 'goals': 22, 'assists': 2, 'mvps': 1},
    'trusted': {'played': 10, 'goals': 8, 'assists': 2, 'mvps': 1},
  },
  'index': 1.23,
  'trophies': [
    {'kind': 'champion', 'tournament': 'Copa Verano', 'teamName': 'Los Tigres'},
  ],
  'settings': {'showPrivateStats': showPrivate},
};

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  test('GlobalProfile.fromJson lee todo, también lo que viene sin nombre', () {
    final p = GlobalProfile.fromJson(profileJson());
    expect(p.username, 'yoan');
    expect(p.index, 1.23);
    expect(p.all.goals, 22);
    expect(p.trusted.played, 10);
    expect(p.memberships.last.hidden, isTrue);
    expect(p.memberships.first.periods.single.frozen, isTrue);
    expect(p.trophies.single.kind, 'champion');
    expect(p.showPrivateStats, isTrue);
  });

  testWidgets(
    'la sección "En toda la app": servidores con su nivel, el privado sin nombre, '
    'la vitrina y el ajuste de privacidad',
    (tester) async {
      final requests = <String, Object?>{};
      var showPrivate = true;
      final client = MockClient((req) async {
        requests['${req.method} ${req.url.path}'] = req.body.isEmpty
            ? null
            : jsonDecode(req.body);
        if (req.method == 'PATCH') {
          showPrivate =
              (jsonDecode(req.body) as Map)['showPrivateStats'] as bool;
          return http.Response('{"settings":{}}', 200);
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(profileJson(showPrivate: showPrivate))),
          200,
        );
      });
      final api = PlayersApi(
        ApiClient(baseUrl: 'https://api.test', client: client),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [playersApiProvider.overrideWithValue(api)],
          child: MaterialApp(
            home: Scaffold(
              body: ListView(
                children: const [GlobalStatsSection(userId: 'u1', isMe: true)],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('En toda la app'), findsOneWidget);
      expect(find.text('1.23'), findsOneWidget);
      expect(find.text('Los Pinos'), findsOneWidget);
      expect(find.text('Servidor privado'), findsOneWidget);
      expect(find.text('Verificado'), findsOneWidget);
      expect(find.text('🏆'), findsOneWidget);
      expect(find.textContaining('Copa Verano'), findsOneWidget);
      expect(find.textContaining('10 jornadas, 8 goles'), findsOneWidget);

      // Abrir el privado: la marca de promedio raro.
      await tester.tap(find.text('Servidor privado'));
      await tester.pumpAndSettle();
      expect(find.textContaining('fuera de lo normal'), findsOneWidget);

      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(requests['PATCH /me'], {'showPrivateStats': false});
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    },
  );
}
