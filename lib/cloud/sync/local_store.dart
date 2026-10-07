import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'club_data.dart';
import 'command.dart';

/// Lo que el teléfono guarda de una cuenta, en archivos JSON dentro de su
/// carpeta privada: un archivo por servidor, la cola de cambios pendientes, los
/// cambios rechazados y la última respuesta de `/me` (para arrancar sin señal).
///
/// Cada cuenta tiene su carpeta: si en el teléfono entra otra persona, no ve
/// nada de la anterior. Cada escritura es atómica (archivo temporal + rename), y
/// las operaciones van de una en una: en Windows, renombrar sobre un archivo que
/// otra operación tiene abierto falla.
///
/// La cola y los rechazados son **un archivo por cambio** (`outbox/`,
/// `rejected/`), nunca un archivo que se lee, se modifica y se reescribe: la app
/// abierta y el sync de segundo plano (otro isolate, con su propio [LocalStore])
/// pueden trabajar a la vez sin que uno borre lo que añadió el otro. Lo peor que
/// pasa es que los dos envíen el mismo cambio, y el servidor lo reconoce como
/// duplicado.
class LocalStore {
  LocalStore(this.root, {this.createsRoot = true});

  final Directory root;

  /// false en el sync de segundo plano: si la carpeta no está (se cerró la
  /// sesión y se borró), lo que escriba se descarta en vez de volver a crearla.
  final bool createsRoot;
  static final _random = Random();

  Future<void> _queue = Future.value();
  Future<T> _serial<T>(Future<T> Function() f) {
    final result = _queue.then((_) => f());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  File _file(String name) => File('${root.path}${Platform.pathSeparator}$name');

  Future<Object?> _read(String name) => _serial(() => _readNow(name));

  Future<Object?> _readNow(String name) async {
    final f = _file(name);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } on FormatException {
      // Un archivo a medias (corte de luz) no tumba la app: se descarta.
      return null;
    } on FileSystemException {
      // Se borró justo entre comprobarlo y leerlo (p. ej. al cerrar sesión).
      return null;
    }
  }

  Future<void> _write(String name, Object? value) =>
      _serial(() => _writeNow(name, value));

  /// Prepara la carpeta para escribir; false si no hay que escribir (ver [createsRoot]).
  Future<bool> _ready([String? sub]) async {
    if (!createsRoot && !await root.exists()) return false;
    // Sin [createsRoot], nunca recursivo: si la carpeta desaparece justo ahora, falla.
    await (sub == null ? root : _dir(sub)).create(recursive: createsRoot);
    return true;
  }

  Future<void> _writeNow(String name, Object? value) async {
    if (!await _ready()) return;
    // Un temporal distinto por escritura: dos escrituras a la vez no se mezclan.
    final tmp = _file(
      '$name.${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 30)}.tmp',
    );
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(_file(name).path);
  }

  String _clubFile(String clubId) => 'club-$clubId.json';

  Future<ClubData?> readClub(String clubId) async {
    final j = await _read(_clubFile(clubId));
    return j is Map<String, dynamic> ? ClubData.fromJson(j) : null;
  }

  Future<void> writeClub(ClubData data) =>
      _write(_clubFile(data.clubId), data.toJson());

  Future<void> deleteClub(String clubId) => _serial(() async {
    final f = _file(_clubFile(clubId));
    if (await f.exists()) await f.delete();
  });

  Future<List<String>> clubIds() => _serial(() async {
    if (!await root.exists()) return const <String>[];
    final ids = <String>[];
    await for (final e in root.list()) {
      final name = e.uri.pathSegments.last;
      if (name.startsWith('club-') && name.endsWith('.json')) {
        ids.add(name.substring(5, name.length - 5));
      }
    }
    return ids;
  });

  static const _outbox = 'outbox';
  static const _rejected = 'rejected';

  /// La cola, en el orden en que se hicieron los cambios.
  Future<List<Command>> readOutbox() async => [
    for (final j in await _readEntries(_outbox))
      Command.fromJson(j as Map<String, dynamic>),
  ];

  /// Añade un cambio al final de la cola.
  Future<void> addToOutbox(Command c) => _addEntry(_outbox, c.id, c.toJson());

  /// Saca de la cola los cambios ya resueltos (los que no estén, se ignoran).
  Future<void> removeFromOutbox(Iterable<String> ids) =>
      _removeEntries(_outbox, ids.toSet());

  Future<List<RejectedChange>> readRejected() async => [
    for (final j in await _readEntries(_rejected))
      RejectedChange.fromJson(j as Map<String, dynamic>),
  ];

  Future<void> addRejected(Iterable<RejectedChange> rejected) async {
    for (final r in rejected) {
      await _addEntry(_rejected, r.command.id, r.toJson());
    }
  }

  Future<void> removeRejected(String commandId) =>
      _removeEntries(_rejected, {commandId});

  Directory _dir(String name) =>
      Directory('${root.path}${Platform.pathSeparator}$name');

  /// Orden de los archivos: un número que crece siempre (microsegundos, pero
  /// nunca por debajo del último que hay en la carpeta, por si el reloj del
  /// teléfono se atrasó) y el id. Los que venían de la versión de un solo
  /// archivo van primero. Solo la app abierta añade a la cola.
  Future<String> _stamp(Directory d) async {
    var last = 0;
    await for (final e in d.list()) {
      final name = e.uri.pathSegments.last;
      if (_idOf(name) == null) continue;
      final n = int.tryParse(name.substring(0, name.indexOf('-'))) ?? 0;
      if (n > last) last = n;
    }
    final now = DateTime.now().microsecondsSinceEpoch;
    return (now > last ? now : last + 1).toString().padLeft(20, '0');
  }

  /// Lo ya leído de la cola y los rechazados, por archivo: cada uno se escribe
  /// una vez (rename) y no cambia, así que no hace falta volver a leerlo.
  final _cache = <String, Object?>{};

  static String? _idOf(String fileName) {
    if (!fileName.endsWith('.json')) return null; // temporales
    final dash = fileName.indexOf('-');
    return dash < 0 ? null : fileName.substring(dash + 1, fileName.length - 5);
  }

  Future<void> _addEntry(String dir, String id, Object? value) =>
      _serial(() async {
        await _migrateLegacy(dir);
        if (!await _ready(dir)) return;
        final stamp = await _stamp(_dir(dir));
        await _writeNow('$dir${Platform.pathSeparator}$stamp-$id.json', value);
      });

  Future<List<Object?>> _readEntries(String dir) => _serial(() async {
    await _migrateLegacy(dir);
    final d = _dir(dir);
    if (!await d.exists()) return const <Object?>[];
    final names = <String>[];
    try {
      await for (final e in d.list()) {
        final name = e.uri.pathSegments.last;
        if (_idOf(name) != null) names.add(name);
      }
    } on FileSystemException {
      return const <Object?>[]; // se borró mientras tanto (al cerrar sesión)
    }
    names.sort();
    final out = <Object?>[];
    final seen = <String>{};
    final listed = <String>{};
    for (final name in names) {
      // Un mismo cambio dos veces (la migración en dos isolates): una sola.
      if (!seen.add(_idOf(name)!)) continue;
      final key = '$dir${Platform.pathSeparator}$name';
      listed.add(key);
      final j = _cache.containsKey(key) ? _cache[key] : await _readNow(key);
      if (j != null) {
        _cache[key] = j;
        out.add(j);
      }
    }
    _cache.removeWhere((k, _) => k.startsWith(dir) && !listed.contains(k));
    return out;
  });

  Future<void> _removeEntries(String dir, Set<String> ids) => _serial(() async {
    if (ids.isEmpty) return;
    await _migrateLegacy(dir);
    final d = _dir(dir);
    if (!await d.exists()) return;
    final files = <File>[];
    try {
      await for (final e in d.list()) {
        final id = _idOf(e.uri.pathSegments.last);
        if (e is File && id != null && ids.contains(id)) files.add(e);
      }
    } on FileSystemException {
      return; // se borró mientras tanto (al cerrar sesión)
    }
    for (final f in files) {
      try {
        await f.delete();
      } on PathNotFoundException {
        // Lo borró el otro isolate.
      }
    }
  });

  /// Hasta la 0.5 la cola era un solo `outbox.json` (y `rejected.json`): se
  /// pasa a un archivo por cambio, conservando el orden.
  Future<void> _migrateLegacy(String dir) async {
    final legacy = _file('$dir.json');
    if (!await legacy.exists()) return;
    final j = await _readNow('$dir.json');
    if (j is List && await _ready(dir)) {
      for (var i = 0; i < j.length; i++) {
        final item = j[i] as Map<String, dynamic>;
        final id = dir == _outbox
            ? item['id']
            : (item['command'] as Map<String, dynamic>)['id'];
        await _writeNow(
          '$dir${Platform.pathSeparator}${i.toString().padLeft(20, '0')}-$id.json',
          item,
        );
      }
    }
    try {
      await legacy.delete();
    } on PathNotFoundException {
      // La migró el otro isolate.
    }
  }

  Future<Map<String, dynamic>?> readMe() async {
    final j = await _read('me.json');
    return j is Map<String, dynamic> ? j : null;
  }

  Future<void> writeMe(Map<String, dynamic> me) => _write('me.json', me);

  /// Qué avisos ya se mostraron (ver `alerts.dart`).
  Future<Map<String, dynamic>?> readAlertLedger() async {
    final j = await _read('alerts.json');
    return j is Map<String, dynamic> ? j : null;
  }

  Future<void> writeAlertLedger(Map<String, Object?> ledger) =>
      _write('alerts.json', ledger);

  /// Borra todo lo de esta cuenta en el teléfono (al cerrar sesión).
  /// Primero se aparta (rename, atómico): el sync de segundo plano, si estaba
  /// escribiendo, ya no encuentra la carpeta y no la vuelve a crear.
  Future<void> wipe() => _serial(() async {
    _cache.clear();
    try {
      final trash = await root.rename(
        '${root.path}.borrar-${DateTime.now().microsecondsSinceEpoch}',
      );
      await trash.delete(recursive: true);
    } on FileSystemException {
      // Ya no existía, o algo quedó a medias: lo que importa es que se apartó.
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } on FileSystemException {
        // Se reintenta en el próximo cierre de sesión.
      }
    }
  });
}
