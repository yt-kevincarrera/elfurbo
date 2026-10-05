import 'dart:convert';
import 'dart:io';

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/sync/club_data.dart';
import 'package:elfurbo/cloud/sync/command.dart';
import 'package:elfurbo/cloud/sync/local_store.dart';
import 'package:elfurbo/cloud/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'sync_test.dart' show FakeServer;

Command _guest(String id) =>
    Command.create('c1', 'member.createGuest', {'id': id});

void main() {
  late Directory dir;
  late FakeServer server;
  late LocalStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bg_sync');
    server = FakeServer();
    store = LocalStore(dir);
  });
  tearDown(() => dir.delete(recursive: true));

  SyncEngine engine({LocalStore? on, Future<bool> Function()? isOutdated}) =>
      SyncEngine(
        api: ApiClient(baseUrl: 'https://api.test', client: server.client),
        store: on ?? store,
        isOutdated: isOutdated,
      );

  group('la app abierta y el sync de segundo plano a la vez', () {
    test(
      'un cambio añadido mientras el otro vacía la cola no se pierde',
      () async {
        // Cada isolate tiene su propio LocalStore sobre la misma carpeta.
        final app = LocalStore(dir);
        final background = LocalStore(dir);
        await app.addToOutbox(_guest('a'));
        await app.addToOutbox(_guest('b'));
        final seen = await background.readOutbox();
        await Future.wait([
          app.addToOutbox(_guest('c')),
          background.removeFromOutbox(seen.map((c) => c.id)),
        ]);
        expect((await app.readOutbox()).map((c) => c.payload['id']), ['c']);
      },
    );

    test(
      'dos sincronizaciones a la vez: todo sale, nada se pierde ni se repite en la cola',
      () async {
        final app = engine(on: LocalStore(dir));
        final background = engine(on: LocalStore(dir));
        for (final id in ['a', 'b', 'c']) {
          await app.enqueue(_guest(id));
        }
        await Future.wait([
          app.sync(),
          background.sync(),
          app.enqueue(_guest('d')),
        ]);
        await app.sync();
        expect(await store.readOutbox(), isEmpty);
        final sent = {
          for (final batch in server.pushed)
            for (final c in batch) (c['payload'] as Map)['id'],
        };
        expect(sent, {'a', 'b', 'c', 'd'});
        expect(await store.readRejected(), isEmpty);
      },
    );

    test('la cola sigue en el orden en que se hicieron los cambios', () async {
      for (final id in ['1', '2', '3', '4', '5']) {
        await store.addToOutbox(_guest(id));
      }
      await store.removeFromOutbox([(await store.readOutbox())[2].id]);
      expect((await LocalStore(dir).readOutbox()).map((c) => c.payload['id']), [
        '1',
        '2',
        '4',
        '5',
      ]);
    });

    test(
      'la cola de un solo archivo (hasta la 0.5) se pasa sin perder nada ni el orden',
      () async {
        final old = [_guest('x'), _guest('y')];
        await File(
          '${dir.path}/outbox.json',
        ).writeAsString(jsonEncode([for (final c in old) c.toJson()]));
        await File('${dir.path}/rejected.json').writeAsString(
          jsonEncode([
            RejectedChange(
              command: _guest('z'),
              code: 'c',
              message: 'm',
            ).toJson(),
          ]),
        );
        await store.addToOutbox(_guest('nuevo'));
        expect((await store.readOutbox()).map((c) => c.payload['id']), [
          'x',
          'y',
          'nuevo',
        ]);
        expect((await store.readRejected()).single.message, 'm');
        expect(File('${dir.path}/outbox.json').existsSync(), isFalse);
      },
    );

    test('quitar un rechazado deja los demás', () async {
      await store.addRejected([
        RejectedChange(command: _guest('a'), code: 'c', message: 'uno'),
        RejectedChange(command: _guest('b'), code: 'c', message: 'dos'),
      ]);
      final first = (await store.readRejected()).first;
      await store.removeRejected(first.command.id);
      expect((await store.readRejected()).map((r) => r.message), ['dos']);
    });
  });

  group('casos raros', () {
    test(
      'si el reloj del teléfono se atrasa, la cola no cambia de orden',
      () async {
        // Un cambio hecho con el reloj adelantado (y la app reiniciada después).
        final future = (DateTime.now().microsecondsSinceEpoch * 2)
            .toString()
            .padLeft(20, '0');
        final early = _guest('antes');
        await Directory('${dir.path}/outbox').create();
        await File(
          '${dir.path}/outbox/$future-${early.id}.json',
        ).writeAsString(jsonEncode(early.toJson()));
        await LocalStore(dir).addToOutbox(_guest('despues'));
        expect(
          (await LocalStore(dir).readOutbox()).map((c) => c.payload['id']),
          ['antes', 'despues'],
        );
      },
    );

    test(
      'al cerrar sesión, el segundo plano no resucita la carpeta borrada',
      () async {
        final account = Directory('${dir.path}/u-1');
        final app = LocalStore(account);
        final background = LocalStore(account, createsRoot: false);
        await app.addToOutbox(_guest('a'));
        await app.wipe();
        await background.writeClub(ClubData(clubId: 'c1', cursor: 9));
        await background.addRejected([
          RejectedChange(command: _guest('a'), code: 'c', message: 'm'),
        ]);
        expect(account.existsSync(), isFalse);
        expect(dir.listSync(), isEmpty); // ni la papelera queda
      },
    );

    test(
      'un pull más viejo que lo guardado por el otro isolate no lo pisa',
      () async {
        await store.writeClub(ClubData(clubId: 'c1', cursor: 20));
        server.pulls = [
          {
            'clubs': {
              'c1': {
                'cursor': 15,
                'hasMore': false,
                'snapshot': false,
                'upserts': {},
                'deletes': {},
              },
            },
            'removed': [],
          },
        ];
        final e = engine();
        // Mientras el pull de esta app viaja, el otro guarda uno más nuevo.
        await e.sync();
        expect((await store.readClub('c1'))!.cursor, 20);
      },
    );
  });

  group('versión vieja', () {
    test('no envía ni trae nada, conserva la cola y lo dice', () async {
      final e = engine(isOutdated: () async => true);
      await e.enqueue(_guest('g'));
      await e.sync();
      expect(e.last.state, SyncState.outdated);
      expect(e.last.pending, 1);
      expect(server.pushed, isEmpty);
      expect(server.pullBodies, isEmpty);
    });

    test('al actualizar vuelve a sincronizar', () async {
      var outdated = true;
      final e = engine(isOutdated: () async => outdated);
      await e.enqueue(_guest('g'));
      await e.sync();
      outdated = false;
      await e.sync();
      expect(e.last.state, SyncState.idle);
      expect(server.pushed, hasLength(1));
    });

    test(
      'si el servidor dice 426, también es "actualiza"; la cola sigue',
      () async {
        final e = SyncEngine(
          api: ApiClient(
            baseUrl: 'https://api.test',
            build: 3,
            client: MockClient((req) async {
              expect(req.headers['x-app-build'], '3');
              return http.Response(
                jsonEncode({
                  'error': {
                    'code': 'app_outdated',
                    'message': 'Actualiza la app para seguir sincronizando',
                  },
                }),
                426,
              );
            }),
          ),
          store: store,
        );
        await e.enqueue(_guest('g'));
        await e.sync();
        expect(e.last.state, SyncState.outdated);
        expect(await store.readOutbox(), hasLength(1));
      },
    );
  });

  test('reintentos: 5 s, 10 s, 20 s… y como mucho 5 min', () {
    expect(CloudController.retryDelay(1), const Duration(seconds: 5));
    expect(CloudController.retryDelay(2), const Duration(seconds: 10));
    expect(CloudController.retryDelay(3), const Duration(seconds: 20));
    expect(CloudController.retryDelay(7), const Duration(minutes: 5));
    expect(CloudController.retryDelay(40), const Duration(minutes: 5));
  });
}
