import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:elfurbo/cloud/api/api_client.dart';
import 'package:elfurbo/cloud/state/cloud_controller.dart';
import 'package:elfurbo/cloud/sync/command.dart';
import 'package:elfurbo/cloud/sync/local_store.dart';
import 'package:elfurbo/cloud/sync/sync_engine.dart';
import 'package:elfurbo/cloud/sync/sync_handoff.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test.dart' show FakeServer;

void main() {
  late Directory dir;
  late FakeServer server;
  late LocalStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bg_sync');
    server = FakeServer();
    store = LocalStore(dir);
  });
  tearDown(() async {
    IsolateNameServer.removePortNameMapping(SyncHandoff.foregroundName);
    IsolateNameServer.removePortNameMapping(SyncHandoff.backgroundName);
    await dir.delete(recursive: true);
  });

  SyncEngine engine({
    Future<bool> Function()? isOutdated,
    Future<void> Function()? gate,
  }) => SyncEngine(
    api: ApiClient(baseUrl: 'https://api.test', client: server.client),
    store: store,
    isOutdated: isOutdated,
    gate: gate,
  );

  group('versión vieja', () {
    test('no envía ni trae nada, conserva la cola y lo dice', () async {
      final e = engine(isOutdated: () async => true);
      await e.enqueue(Command.create('c1', 'member.createGuest', {'id': 'g'}));
      await e.sync();
      expect(e.last.state, SyncState.outdated);
      expect(e.last.pending, 1);
      expect(server.pushed, isEmpty);
      expect(server.pullBodies, isEmpty);
    });

    test('al actualizar vuelve a sincronizar', () async {
      var outdated = true;
      final e = engine(isOutdated: () async => outdated);
      await e.enqueue(Command.create('c1', 'member.createGuest', {'id': 'g'}));
      await e.sync();
      outdated = false;
      await e.sync();
      expect(e.last.state, SyncState.idle);
      expect(server.pushed, hasLength(1));
    });
  });

  test(
    'la compuerta se espera antes de tocar la cola y antes de sincronizar',
    () async {
      final open = Completer<void>();
      final e = engine(gate: () => open.future);
      var enqueued = false;
      final enqueue = e
          .enqueue(Command.create('c1', 'member.createGuest', {'id': 'g'}))
          .then((_) => enqueued = true);
      final sync = e.sync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(enqueued, isFalse);
      expect(await store.readOutbox(), isEmpty);
      expect(server.pullBodies, isEmpty);
      open.complete();
      await enqueue;
      await sync;
      expect(enqueued, isTrue);
      expect(server.pullBodies, isNotEmpty);
    },
  );

  test('reintentos: 5 s, 10 s, 20 s… y como mucho 5 min', () {
    expect(CloudController.retryDelay(1), const Duration(seconds: 5));
    expect(CloudController.retryDelay(2), const Duration(seconds: 10));
    expect(CloudController.retryDelay(3), const Duration(seconds: 20));
    expect(CloudController.retryDelay(7), const Duration(minutes: 5));
    expect(CloudController.retryDelay(40), const Duration(minutes: 5));
  });

  group('turnos entre la app y el segundo plano', () {
    test(
      'con la app abierta, el de segundo plano no sincroniza: se lo pide a ella',
      () async {
        final fg = ForegroundSyncHandoff();
        var asked = 0;
        fg.start(onSyncRequest: () => asked++);
        await fg.gate();

        final bg = BackgroundSyncHandoff();
        expect(await bg.acquire(onStop: () {}), isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(asked, 1);
        // Y no se queda con el turno.
        expect(
          IsolateNameServer.lookupPortByName(SyncHandoff.backgroundName),
          isNull,
        );
        fg.dispose();
      },
    );

    test(
      'una app que murió sin despedirse no bloquea el segundo plano',
      () async {
        final dead = ReceivePort();
        IsolateNameServer.registerPortWithName(
          dead.sendPort,
          SyncHandoff.foregroundName,
        );
        dead.close();

        final bg = BackgroundSyncHandoff(
          pingTimeout: const Duration(milliseconds: 50),
        );
        expect(await bg.acquire(onStop: () {}), isTrue);
        expect(
          IsolateNameServer.lookupPortByName(SyncHandoff.foregroundName),
          isNull,
        );
        bg.release();
      },
    );

    test(
      'si la app abre mientras sincroniza el de segundo plano, espera a que pare',
      () async {
        final bg = BackgroundSyncHandoff();
        final stopAsked = Completer<void>();
        expect(await bg.acquire(onStop: stopAsked.complete), isTrue);

        final fg = ForegroundSyncHandoff();
        fg.start(onSyncRequest: () {});
        var through = false;
        final gate = fg.gate().then((_) => through = true);
        await stopAsked.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(through, isFalse);

        bg.release(); // terminó lo que estaba escribiendo
        await gate;
        expect(through, isTrue);
        fg.dispose();
      },
    );

    test(
      'si el de segundo plano no contesta, la app sigue tras el plazo',
      () async {
        final silent = ReceivePort(); // anunciado, pero nunca contesta
        IsolateNameServer.registerPortWithName(
          silent.sendPort,
          SyncHandoff.backgroundName,
        );
        final fg = ForegroundSyncHandoff(
          stopTimeout: const Duration(milliseconds: 100),
        );
        fg.start(onSyncRequest: () {});
        await fg.gate().timeout(const Duration(seconds: 2));
        silent.close();
        fg.dispose();
      },
    );
  });
}
