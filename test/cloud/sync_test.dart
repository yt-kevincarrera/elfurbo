import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/sync/club_data.dart';
import 'package:elfurbo/cloud/sync/command.dart';
import 'package:elfurbo/cloud/sync/local_store.dart';
import 'package:elfurbo/cloud/sync/reducers.dart';
import 'package:elfurbo/cloud/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Un servidor falso: decide el resultado de cada comando y responde al pull.
class FakeServer {
  /// Resultado por tipo de comando (por defecto, applied).
  Map<String, Map<String, Object?>> resultByType = {};

  /// Cuántos comandos acepta por envío antes de aplazar el resto.
  int budget = 1000;
  final pushed = <List<Map<String, dynamic>>>[];
  final pullBodies = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> pulls = [];
  Object? failWith;

  MockClient get client => MockClient((req) async {
    if (failWith != null) throw failWith!;
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    if (req.url.path == '/sync/push') {
      final cmds = (body['commands'] as List).cast<Map<String, dynamic>>();
      pushed.add(cmds);
      var i = 0;
      return http.Response(
        jsonEncode({
          'results': [
            for (final c in cmds)
              {
                'id': c['id'],
                ...(i++ < budget
                    ? resultByType[c['type']] ?? {'status': 'applied'}
                    : {
                        'status': 'deferred',
                        'code': 'budget',
                        'message': 'luego',
                      }),
              },
          ],
        }),
        200,
      );
    }
    pullBodies.add(body);
    final next = pulls.isEmpty
        ? {'clubs': {}, 'removed': []}
        : pulls.removeAt(0);
    return http.Response(jsonEncode(next), 200);
  });
}

Map<String, dynamic> snapshotOf(
  String clubId, {
  List<Map<String, Object?>> members = const [],
  int cursor = 10,
  bool hasMore = false,
}) => {
  'clubs': {
    clubId: {
      'cursor': cursor,
      'hasMore': hasMore,
      'snapshot': true,
      'upserts': {
        'club': [
          {
            'id': clubId,
            'name': 'Pachanga',
            'status': 'active',
            'settings': {'closeAfterHours': 72},
          },
        ],
        'member': members,
      },
      'deletes': {},
    },
  },
  'removed': [],
};

void main() {
  late Directory dir;
  late LocalStore store;
  late FakeServer server;
  late SyncEngine engine;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('furbo-test');
    store = LocalStore(dir);
    server = FakeServer();
    engine = SyncEngine(
      api: ApiClient(baseUrl: 'https://api.test', client: server.client),
      store: store,
    );
  });

  tearDown(() async {
    engine.dispose();
    // Puede quedar alguna escritura en vuelo del sync de fondo: no hace fallar el test.
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Ya no existe o la está usando otra operación que termina enseguida.
    }
  });

  group('LocalStore', () {
    test(
      'guarda y lee servidores, cola y rechazados; wipe borra todo',
      () async {
        final d = ClubData(clubId: 'c1', cursor: 7)
          ..table('member')['m1'] = {'id': 'm1', 'displayName': 'Ñico'};
        await store.writeClub(d);
        await store.writeClub(
          d..cursor = 8,
        ); // sobrescribir un archivo existente
        expect((await store.readClub('c1'))!.cursor, 8);
        expect(
          (await store.readClub('c1'))!.one('member', 'm1')!['displayName'],
          'Ñico',
        );
        expect(await store.clubIds(), ['c1']);
        await store.writeOutbox([Command.create('c1', 'member.leave', {})]);
        expect(await store.readOutbox(), hasLength(1));
        await store.wipe();
        expect(await store.clubIds(), isEmpty);
        expect(await store.readOutbox(), isEmpty);
      },
    );

    test(
      'un archivo a medias (corte de luz) se descarta en vez de romper',
      () async {
        await dir.create(recursive: true);
        await File(
          '${dir.path}${Platform.pathSeparator}outbox.json',
        ).writeAsString('[{"id":');
        expect(await store.readOutbox(), isEmpty);
      },
    );
  });

  group('vista optimista', () {
    test(
      'los pendientes se ven al instante y en orden; un tipo desconocido no hace nada',
      () {
        final server = ClubData(clubId: 'c1')
          ..table('member')['m1'] = {
            'id': 'm1',
            'displayName': 'Raúl',
            'role': 'player',
            'status': 'active',
          };
        final pending = [
          Command.create('c1', 'member.createGuest', {
            'id': 'g1',
            'displayName': 'Yoandry',
          }),
          Command.create('c1', 'member.update', {
            'memberId': 'g1',
            'nickname': 'El primo',
          }),
          Command.create('c1', 'member.setRole', {
            'memberId': 'm1',
            'role': 'scorer',
          }),
          Command.create('c1', 'matchday.teleport', {}),
          Command.create('otro', 'member.ban', {'memberId': 'm1'}),
        ];
        final view = clubView(server, pending, myMemberId: 'm1');
        expect(view.one('member', 'g1'), containsPair('nickname', 'El primo'));
        expect(view.one('member', 'm1'), containsPair('role', 'scorer'));
        expect(view.one('member', 'm1'), containsPair('status', 'active'));
        expect(
          server.one('member', 'g1'),
          isNull,
          reason: 'el estado del servidor no se toca',
        );
      },
    );

    test(
      'temporadas: crear una activa desactiva las demás; cerrar la desactiva',
      () {
        final server = ClubData(clubId: 'c1')
          ..table('season')['s1'] = {
            'id': 's1',
            'isActive': true,
            'isClosed': false,
          };
        final view = clubView(server, [
          Command.create('c1', 'season.create', {
            'id': 's2',
            'name': '2027',
            'startDate': '2027-01-01',
            'activate': true,
          }),
          Command.create('c1', 'season.setClosed', {
            'seasonId': 's2',
            'closed': true,
          }),
        ], myMemberId: null);
        expect(view.one('season', 's1')!['isActive'], isFalse);
        expect(view.one('season', 's2'), containsPair('isClosed', true));
        expect(view.one('season', 's2'), containsPair('isActive', false));
      },
    );

    test('ajustes y transferencia', () {
      final server = ClubData(clubId: 'c1')
        ..table('club')['c1'] = {
          'id': 'c1',
          'settings': {'closeAfterHours': 72, 'reportValidation': 'confirm'},
        }
        ..table('member')['o'] = {'id': 'o', 'role': 'owner'}
        ..table('member')['p'] = {'id': 'p', 'role': 'player'};
      final view = clubView(server, [
        Command.create('c1', 'club.updateSettings', {
          'reportValidation': 'trust',
        }),
        Command.create('c1', 'club.transferOwnership', {'memberId': 'p'}),
      ], myMemberId: 'o');
      expect(view.club!['settings'], {
        'closeAfterHours': 72,
        'reportValidation': 'trust',
      });
      expect(view.one('member', 'o')!['role'], 'admin');
      expect(view.one('member', 'p')!['role'], 'owner');
    });
  });

  group('SyncEngine', () {
    test(
      'envía la cola, la vacía con lo aplicado y guarda la foto del servidor',
      () async {
        server.pulls = [
          snapshotOf(
            'c1',
            members: [
              {'id': 'g1', 'displayName': 'Yoandry'},
            ],
          ),
        ];
        await engine.enqueue(
          Command.create('c1', 'member.createGuest', {
            'id': 'g1',
            'displayName': 'Yoandry',
          }),
        );
        await engine.sync();
        expect(server.pushed.single, hasLength(1));
        expect(await store.readOutbox(), isEmpty);
        final c1 = (await store.readClub('c1'))!;
        expect(c1.cursor, 10);
        expect(c1.one('member', 'g1'), isNotNull);
        expect(engine.last.state, SyncState.idle);
        expect(engine.last.lastSync, isNotNull);
      },
    );

    test(
      'un rechazo sale de la cola y queda en "Cambios no aplicados" con su motivo',
      () async {
        server.resultByType['member.ban'] = {
          'status': 'rejected',
          'code': 'forbidden',
          'message': 'No tienes permiso para hacer esto',
        };
        await engine.enqueue(
          Command.create('c1', 'member.ban', {'memberId': 'm1'}),
        );
        await engine.sync();
        expect(await store.readOutbox(), isEmpty);
        final rejected = await store.readRejected();
        expect(rejected.single.message, 'No tienes permiso para hacer esto');
        expect(engine.last.rejected, 1);
        await engine.dismissRejected(rejected.single.command.id);
        expect(await store.readRejected(), isEmpty);
      },
    );

    test(
      'lo aplazado por presupuesto se reenvía en la siguiente tanda hasta vaciar la cola',
      () async {
        server.budget = 2;
        for (var i = 0; i < 5; i++) {
          await engine.enqueue(
            Command.create('c1', 'member.createGuest', {
              'id': 'g$i',
              'displayName': 'J$i',
            }),
          );
        }
        await engine.sync();
        expect(server.pushed.map((b) => b.length), [5, 3, 1]);
        expect(await store.readOutbox(), isEmpty);
      },
    );

    test(
      'un tipo que el servidor aún no conoce se queda en la cola sin bucle infinito',
      () async {
        server.resultByType['matchday.teleport'] = {
          'status': 'deferred',
          'code': 'unknown_command',
          'message': 'luego',
        };
        await engine.enqueue(Command.create('c1', 'matchday.teleport', {}));
        await engine.sync();
        expect(server.pushed, hasLength(1));
        expect(await store.readOutbox(), hasLength(1));
        expect(engine.last.state, SyncState.idle);
        expect(engine.last.pending, 1);
      },
    );

    test('sin señal: estado offline y la cola intacta', () async {
      await engine.enqueue(Command.create('c1', 'member.leave', {}));
      server.failWith = const SocketException('sin red');
      await engine.sync();
      expect(engine.last.state, SyncState.offline);
      expect(await store.readOutbox(), hasLength(1));
    });

    test(
      'sesión caducada (401): estado unauthorized y la cola se conserva',
      () async {
        final engine401 = SyncEngine(
          api: ApiClient(
            baseUrl: 'https://api.test',
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'error': {
                    'code': 'session_expired',
                    'message': 'Tu sesión caducó',
                  },
                }),
                401,
              ),
            ),
          ),
          store: store,
        );
        await engine401.enqueue(Command.create('c1', 'member.leave', {}));
        await engine401.sync();
        expect(engine401.last.state, SyncState.unauthorized);
        expect(await store.readOutbox(), hasLength(1));
        engine401.dispose();
      },
    );

    test(
      'un error interno deja el comando para otra vez y no sigue empujando',
      () async {
        server.resultByType['member.leave'] = {
          'status': 'error',
          'code': 'internal',
          'message': 'x',
        };
        await engine.enqueue(Command.create('c1', 'member.leave', {}));
        await engine.sync();
        expect(server.pushed, hasLength(1));
        expect(await store.readOutbox(), hasLength(1));
      },
    );

    test(
      'pull paginado (hasMore) e incremental con el cursor guardado; removed borra el servidor',
      () async {
        server.pulls = [
          snapshotOf('c1', cursor: 5, hasMore: true),
          {
            'clubs': {
              'c1': {
                'cursor': 9,
                'hasMore': false,
                'snapshot': false,
                'upserts': {
                  'member': [
                    {'id': 'm2', 'displayName': 'Pepe'},
                  ],
                },
                'deletes': {},
              },
            },
            'removed': [],
          },
        ];
        await engine.sync();
        expect(server.pullBodies.map((b) => b['cursors']), [
          {},
          {'c1': 5},
        ]);
        expect((await store.readClub('c1'))!.cursor, 9);
        expect((await store.readClub('c1'))!.one('member', 'm2'), isNotNull);

        server.pulls = [
          {
            'clubs': {},
            'removed': ['c1'],
          },
        ];
        await engine.sync();
        expect(await store.clubIds(), isEmpty);
      },
    );

    test(
      'un cambio que entra mientras se envía la cola no se pierde',
      () async {
        await engine.enqueue(
          Command.create('c1', 'member.createGuest', {
            'id': 'g1',
            'displayName': 'A',
          }),
        );
        final syncing = engine.sync();
        await engine.enqueue(
          Command.create('c1', 'member.createGuest', {
            'id': 'g2',
            'displayName': 'B',
          }),
        );
        await syncing;
        await engine.sync();
        final sent = server.pushed
            .expand((b) => b)
            .map((c) => (c['payload'] as Map)['id'])
            .toSet();
        expect(sent, {'g1', 'g2'});
        expect(await store.readOutbox(), isEmpty);
      },
    );
  });
}
