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
/// - Aplicado: sale de la cola, pero se sigue aplicando encima en la vista hasta
///   que llegue el pull que ya lo trae (si el pull falla, el cambio no "desaparece").
/// - Duplicado: igual que su resultado original (aplicado o rechazado).
/// - Rechazado: sale de la cola y pasa a "Cambios no aplicados" con su motivo.
/// - Aplazado (`deferred`): se queda en la cola y se reenvía en la siguiente tanda.
/// - Error interno o sin señal: se queda todo y se reintenta más tarde.
/// - Envío demasiado grande (413) o mal formado (400): se parte en tandas más
///   pequeñas; un único comando que el servidor no admite pasa a rechazados.
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

  /// Avisa cuando cambió algo en el teléfono (cola o datos de servidores).
  final _changed = StreamController<void>.broadcast();
  Stream<void> get changed => _changed.stream;

  Future<void>? _running;
  bool _again = false;
  bool _closed = false;

  /// Aplicados por el servidor que todavía no llegaron por el pull.
  final _acked = <Command>[];

  /// Toda modificación de la cola pasa por aquí, de una en una: si se añade un cambio
  /// mientras el push la reescribe, ninguno pisa al otro. Lo mismo para los rechazados.
  Future<void> _outboxLock = Future.value();
  Future<void> _rejectedLock = Future.value();

  Future<T> _locked<T>(
    Future<void> Function() get,
    void Function(Future<void>) set,
    Future<T> Function() f,
  ) {
    final result = get().then((_) => f());
    set(result.then<void>((_) {}, onError: (_) {}));
    return result;
  }

  Future<T> _withOutbox<T>(Future<T> Function(List<Command> outbox) f) =>
      _locked(
        () => _outboxLock,
        (l) => _outboxLock = l,
        () async => f(await store.readOutbox()),
      );

  Future<T> _withRejected<T>(Future<T> Function(List<RejectedChange> all) f) =>
      _locked(
        () => _rejectedLock,
        (l) => _rejectedLock = l,
        () async => f(await store.readRejected()),
      );

  /// Añade un cambio a la cola (y lo deja visible al instante en la vista).
  Future<void> enqueue(Command c) async {
    await _withOutbox((outbox) => store.writeOutbox([...outbox, c]));
    _notify();
  }

  /// Los cambios que la vista aplica encima del servidor: los aplicados que aún
  /// no llegaron por el pull y, después, los de la cola, en orden.
  Future<List<Command>> pending() =>
      _withOutbox((outbox) async => [..._acked, ...outbox]);

  /// Sincroniza. Si ya hay una en marcha, se encadena otra al terminar.
  Future<void> sync() {
    if (_closed) return Future.value();
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
    } while (_again && !_closed);
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
    } catch (e) {
      // Nada deja el indicador en "Sincronizando…" para siempre.
      await _emit(SyncState.error, message: 'No se pudo sincronizar');
    }
  }

  Future<void> _push() async {
    var size = batchSize;
    for (var round = 0; round < maxRounds && !_closed; round++) {
      final outbox = await store.readOutbox();
      if (outbox.isEmpty) return;
      final batch = outbox.take(size).toList();
      Map<String, dynamic>? res;
      try {
        res = await api.post('/sync/push', {
          'commands': [for (final c in batch) c.toJson()],
        });
      } on ApiException catch (e) {
        if (e.status != 413 && e.status != 400) rethrow;
        if (batch.length > 1) {
          size = (batch.length / 2).ceil();
          continue;
        }
        // Un solo comando que el servidor no admite: no puede bloquear la cola.
        await _finish(
          {batch.single.id},
          [
            RejectedChange(
              command: batch.single,
              code: e.code,
              message: e.message,
            ),
          ],
        );
        continue;
      }
      if (_closed) return;
      final results = {
        for (final r in (res!['results'] as List))
          (r as Map)['id'] as String: r,
      };

      final done = <String>{};
      final rejected = <RejectedChange>[];
      var stop = false;
      for (final c in batch) {
        var r = results[c.id];
        if (r?['status'] == 'duplicate') {
          r = r!['original'] as Map? ?? {'status': 'applied'};
        }
        switch (r?['status']) {
          case 'applied':
            done.add(c.id);
            _acked.add(c);
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
      await _finish(done, rejected);
      // Sin avance (todo aplazado por un tipo que el servidor aún no conoce, o error): basta por hoy.
      if (stop || done.isEmpty) return;
    }
  }

  /// Saca de la cola lo resuelto. Los rechazos se guardan antes, para que un corte
  /// entre las dos escrituras solo cause un reenvío (que volverá como duplicado).
  Future<void> _finish(Set<String> done, List<RejectedChange> rejected) async {
    if (_closed) return;
    if (rejected.isNotEmpty) {
      await _withRejected((all) => store.writeRejected([...all, ...rejected]));
    }
    await _withOutbox(
      (now) => store.writeOutbox([
        for (final c in now)
          if (!done.contains(c.id)) c,
      ]),
    );
    if (done.isNotEmpty) _notify();
  }

  Future<void> _pull() async {
    for (var round = 0; round < maxRounds && !_closed; round++) {
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
      if (_closed) return;
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
      if (!more) {
        // El estado del servidor ya trae lo aplicado: deja de hacer falta encima.
        _acked.clear();
        _notify();
        return;
      }
      if (pulled.isNotEmpty || (res['removed'] as List).isNotEmpty) _notify();
    }
  }

  void _notify() {
    if (!_closed) _changed.add(null);
  }

  Future<void> _emit(
    SyncState state, {
    DateTime? lastSync,
    String? message,
  }) async {
    if (_closed) return;
    final pending = (await store.readOutbox()).length;
    final rejected = (await store.readRejected()).length;
    if (_closed) return;
    last = SyncStatus(
      state: state,
      pending: pending,
      rejected: rejected,
      lastSync: lastSync ?? last.lastSync,
      message: message,
    );
    _status.add(last);
  }

  /// Quita un cambio de "Cambios no aplicados" (el usuario lo descartó).
  Future<void> dismissRejected(String commandId) async {
    await _withRejected(
      (all) => store.writeRejected([
        for (final r in all)
          if (r.command.id != commandId) r,
      ]),
    );
    await _emit(last.state);
  }

  /// Deja de trabajar: espera a que termine lo que estaba en marcha y no escribe
  /// nada más. Se llama antes de cerrar sesión o de cambiar de cuenta.
  Future<void> close() async {
    _closed = true;
    try {
      await _running;
    } catch (_) {
      // Lo que falle al cerrar ya no importa.
    }
    // Sin esperar: un oyente pausado no puede dejar colgado el cierre de sesión.
    unawaited(_status.close());
    unawaited(_changed.close());
  }

  void dispose() {
    _closed = true;
    _status.close();
    _changed.close();
  }
}
