import 'dart:async';

import '../api/api_client.dart';
import 'club_data.dart';
import 'command.dart';
import 'local_store.dart';

/// Cómo terminó una sincronización, para el indicador de la barra superior.
enum SyncState { idle, syncing, offline, error, unauthorized }

class SyncStatus {
  const SyncStatus({
    required this.state,
    this.pending = 0,
    this.rejected = 0,
    this.lastSync,
    this.message,
  });

  final SyncState state;
  final int pending;
  final int rejected;
  final DateTime? lastSync;
  final String? message;
}

/// Envía la cola de cambios (push) y trae lo nuevo de cada servidor (pull).
///
/// - Aplicado o duplicado: sale de la cola.
/// - Rechazado: sale de la cola y pasa a "Cambios no aplicados" con su motivo.
/// - Aplazado (`deferred`): se queda en la cola y se reenvía en la siguiente tanda.
/// - Error interno o sin señal: se queda todo y se reintenta más tarde.
/// - 401: la sesión caducó; la cola se conserva para cuando vuelva a entrar.
class SyncEngine {
  SyncEngine({
    required this.api,
    required this.store,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ApiClient api;
  final LocalStore store;
  final DateTime Function() _clock;

  /// Máximo de comandos por envío (lo que admite el servidor).
  static const batchSize = 200;

  /// Tandas de push y de pull por sincronización, para no quedarse en bucle.
  static const maxRounds = 20;

  final _status = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get status => _status.stream;
  SyncStatus last = const SyncStatus(state: SyncState.idle);

  /// Se completa cuando cambió algo en el teléfono (cola o datos de servidores).
  final _changed = StreamController<void>.broadcast();
  Stream<void> get changed => _changed.stream;

  Future<void>? _running;
  bool _again = false;

  /// Toda modificación de la cola pasa por aquí, de una en una: si se añade un cambio
  /// mientras el push la reescribe, ninguno pisa al otro.
  Future<void> _outboxLock = Future.value();
  Future<T> _withOutbox<T>(Future<T> Function(List<Command> outbox) f) {
    final result = _outboxLock.then((_) async => f(await store.readOutbox()));
    _outboxLock = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Añade un cambio a la cola (y lo deja visible al instante en la vista).
  Future<void> enqueue(Command c) async {
    await _withOutbox((outbox) => store.writeOutbox([...outbox, c]));
    _changed.add(null);
  }

  /// Los cambios pendientes, para calcular la vista.
  Future<List<Command>> pending() => _withOutbox((outbox) async => outbox);

  /// Sincroniza. Si ya hay una en marcha, se encadena otra al terminar.
  Future<void> sync() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _once();
    } while (_again);
  }

  Future<void> _once() async {
    await _emit(SyncState.syncing);
    try {
      await _push();
      await _pull();
      await _emit(SyncState.idle, lastSync: _clock());
    } on OfflineException {
      await _emit(SyncState.offline);
    } on ApiException catch (e) {
      await _emit(
        e.status == 401 ? SyncState.unauthorized : SyncState.error,
        message: e.message,
      );
    }
  }

  Future<void> _push() async {
    for (var round = 0; round < maxRounds; round++) {
      final outbox = await store.readOutbox();
      if (outbox.isEmpty) return;
      final batch = outbox.take(batchSize).toList();
      final res = await api.post('/sync/push', {
        'commands': [for (final c in batch) c.toJson()],
      });
      final results = {
        for (final r in (res!['results'] as List))
          (r as Map)['id'] as String: r,
      };

      final done = <String>{};
      final rejected = <RejectedChange>[];
      var stop = false;
      for (final c in batch) {
        final r = results[c.id];
        switch (r?['status']) {
          case 'applied' || 'duplicate':
            done.add(c.id);
          case 'rejected':
            done.add(c.id);
            rejected.add(
              RejectedChange(
                command: c,
                code: '${r!['code']}',
                message: '${r['message']}',
              ),
            );
          case 'error':
            stop =
                true; // Fallo del servidor: se reintenta en otra sincronización.
          default: // deferred (o sin respuesta): se queda en la cola.
        }
      }
      if (rejected.isNotEmpty) {
        await store.writeRejected([...await store.readRejected(), ...rejected]);
      }
      // Se relee la cola dentro del cerrojo: mientras tanto pudieron entrar cambios nuevos.
      await _withOutbox(
        (now) => store.writeOutbox([
          for (final c in now)
            if (!done.contains(c.id)) c,
        ]),
      );
      if (done.isNotEmpty) _changed.add(null);
      // Sin avance (todo aplazado por un tipo que el servidor aún no conoce, o error): basta por hoy.
      if (stop || done.isEmpty) return;
    }
  }

  Future<void> _pull() async {
    for (var round = 0; round < maxRounds; round++) {
      final known = await store.clubIds();
      final cursors = <String, int>{};
      final clubs = <String, ClubData>{};
      for (final id in known) {
        final d = await store.readClub(id);
        if (d == null) continue;
        clubs[id] = d;
        cursors[id] = d.cursor;
      }
      final res = await api.post('/sync/pull', {'cursors': cursors});
      final pulled = (res!['clubs'] as Map).cast<String, dynamic>();
      var more = false;
      for (final e in pulled.entries) {
        final data = clubs[e.key] ?? ClubData(clubId: e.key);
        data.applyPull(e.value as Map<String, dynamic>);
        await store.writeClub(data);
        if ((e.value as Map)['hasMore'] == true) more = true;
      }
      for (final id in (res['removed'] as List)) {
        await store.deleteClub('$id');
      }
      if (pulled.isNotEmpty || (res['removed'] as List).isNotEmpty) {
        _changed.add(null);
      }
      if (!more) return;
    }
  }

  Future<void> _emit(
    SyncState state, {
    DateTime? lastSync,
    String? message,
  }) async {
    last = SyncStatus(
      state: state,
      pending: (await store.readOutbox()).length,
      rejected: (await store.readRejected()).length,
      lastSync: lastSync ?? last.lastSync,
      message: message,
    );
    _status.add(last);
  }

  /// Quita un cambio de "Cambios no aplicados" (el usuario lo descartó).
  Future<void> dismissRejected(String commandId) async {
    final all = await store.readRejected();
    await store.writeRejected([
      for (final r in all)
        if (r.command.id != commandId) r,
    ]);
    await _emit(last.state);
  }

  void dispose() {
    _status.close();
    _changed.close();
  }
}
