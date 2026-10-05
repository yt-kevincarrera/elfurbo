import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

/// Turnos entre la app abierta y el sync de segundo plano (WorkManager).
///
/// Los dos usan los mismos archivos de la cuenta (la cola, los servidores) y
/// corren en isolates distintos del mismo proceso, así que no pueden escribir a
/// la vez: un cambio añadido a la cola mientras el otro la reescribe se perdería.
///
/// - La app, al arrancar, se anuncia ([ForegroundSyncHandoff.start]). Si el de
///   segundo plano estaba sincronizando, le pide que pare y espera a que termine
///   antes de tocar la cola ([ForegroundSyncHandoff.gate]).
/// - El de segundo plano se anuncia y, si la app está abierta (responde), no
///   sincroniza: le pide a ella que lo haga ([BackgroundSyncHandoff.acquire]).
///
/// Cada lado se anuncia antes de mirar al otro, así que al menos uno ve al otro.
/// Si la app murió sin borrar su nombre (Android mata la interfaz pero deja el
/// proceso), no responde y el de segundo plano lo borra y sigue.
abstract final class SyncHandoff {
  static const foregroundName = 'elfurbo.sync.foreground';
  static const backgroundName = 'elfurbo.sync.background';

  /// Mensajes. Un [SendPort] suelto es un "¿sigues ahí?" (o "para", para el de
  /// segundo plano) que se contesta por ese puerto.
  static const syncNow = 'sync';
  static const pong = 'pong';
  static const stopped = 'stopped';

  static void _announce(String name, SendPort port) {
    IsolateNameServer.removePortNameMapping(name);
    IsolateNameServer.registerPortWithName(port, name);
  }
}

/// El lado de la app abierta.
class ForegroundSyncHandoff {
  ForegroundSyncHandoff({
    this.stopTimeout = const Duration(seconds: 10),
    this.pollEvery = const Duration(milliseconds: 200),
  });

  final Duration stopTimeout;
  final Duration pollEvery;
  final _port = ReceivePort();
  Future<void>? _takeover;

  /// Se anuncia y atiende al de segundo plano: responde a sus "¿sigues ahí?" y
  /// sincroniza cuando él lo pide (ver [onSyncRequest]).
  void start({required void Function() onSyncRequest}) {
    SyncHandoff._announce(SyncHandoff.foregroundName, _port.sendPort);
    _port.listen((msg) {
      if (msg is SendPort) {
        msg.send(SyncHandoff.pong);
      } else if (msg == SyncHandoff.syncNow) {
        onSyncRequest();
      }
    });
    _takeover = _stopBackground();
  }

  /// Esperar antes de tocar la cola: si el de segundo plano estaba en marcha,
  /// termina primero (como mucho [stopTimeout]).
  Future<void> gate() => _takeover ?? Future.value();

  Future<void> _stopBackground() async {
    final bg = IsolateNameServer.lookupPortByName(SyncHandoff.backgroundName);
    if (bg == null) return;
    final reply = ReceivePort();
    try {
      bg.send(reply.sendPort);
      // Termina cuando contesta "parado" o cuando su nombre desaparece (acabó
      // por su cuenta y ya no leerá el mensaje).
      // Al cerrar el puerto sin respuesta, `first` falla: no es un error.
      final answered = reply.first
          .then((_) => true)
          .catchError((Object _) => false);
      final deadline = DateTime.now().add(stopTimeout);
      while (DateTime.now().isBefore(deadline)) {
        final done = await Future.any([
          answered,
          Future.delayed(pollEvery, () => false),
        ]);
        if (done) return;
        if (IsolateNameServer.lookupPortByName(SyncHandoff.backgroundName) !=
            bg) {
          return;
        }
      }
    } finally {
      reply.close();
    }
  }

  void dispose() {
    final mine = IsolateNameServer.lookupPortByName(SyncHandoff.foregroundName);
    if (mine == _port.sendPort) {
      IsolateNameServer.removePortNameMapping(SyncHandoff.foregroundName);
    }
    _port.close();
  }
}

/// El lado del sync de segundo plano.
class BackgroundSyncHandoff {
  BackgroundSyncHandoff({this.pingTimeout = const Duration(seconds: 2)});

  final Duration pingTimeout;
  final _port = ReceivePort();
  final _stopRequests = <SendPort>[];
  void Function()? _onStop;

  /// true si puede sincronizar él. false si la app está abierta: entonces ya le
  /// pidió que sincronice ella y no hay que hacer nada más (ni [release]).
  /// [onStop] se llama si la app arranca mientras tanto y pide el turno.
  Future<bool> acquire({required void Function() onStop}) async {
    _onStop = onStop;
    SyncHandoff._announce(SyncHandoff.backgroundName, _port.sendPort);
    _port.listen((msg) {
      if (msg is SendPort) {
        _stopRequests.add(msg);
        _onStop?.call();
      }
    });
    final fg = IsolateNameServer.lookupPortByName(SyncHandoff.foregroundName);
    if (fg != null && await _alive(fg)) {
      fg.send(SyncHandoff.syncNow);
      _leave();
      return false;
    }
    if (fg != null) {
      // Una app que murió sin despedirse.
      IsolateNameServer.removePortNameMapping(SyncHandoff.foregroundName);
    }
    return true;
  }

  Future<bool> _alive(SendPort port) async {
    final reply = ReceivePort();
    try {
      port.send(reply.sendPort);
      await reply.first.timeout(pingTimeout);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      reply.close();
    }
  }

  /// Terminó (o paró): avisa a la app si esperaba y deja el turno.
  void release() => _leave();

  void _leave() {
    for (final r in _stopRequests) {
      r.send(SyncHandoff.stopped);
    }
    _stopRequests.clear();
    final mine = IsolateNameServer.lookupPortByName(SyncHandoff.backgroundName);
    if (mine == _port.sendPort) {
      IsolateNameServer.removePortNameMapping(SyncHandoff.backgroundName);
    }
    _port.close();
  }
}
