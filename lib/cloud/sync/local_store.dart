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
class LocalStore {
  LocalStore(this.root);

  final Directory root;
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

  Future<void> _writeNow(String name, Object? value) async {
    await root.create(recursive: true);
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

  Future<List<Command>> readOutbox() async {
    final j = await _read('outbox.json');
    return j is List
        ? [for (final c in j) Command.fromJson(c as Map<String, dynamic>)]
        : [];
  }

  Future<void> writeOutbox(List<Command> commands) =>
      _write('outbox.json', [for (final c in commands) c.toJson()]);

  Future<List<RejectedChange>> readRejected() async {
    final j = await _read('rejected.json');
    return j is List
        ? [
            for (final r in j)
              RejectedChange.fromJson(r as Map<String, dynamic>),
          ]
        : [];
  }

  Future<void> writeRejected(List<RejectedChange> rejected) =>
      _write('rejected.json', [for (final r in rejected) r.toJson()]);

  Future<Map<String, dynamic>?> readMe() async {
    final j = await _read('me.json');
    return j is Map<String, dynamic> ? j : null;
  }

  Future<void> writeMe(Map<String, dynamic> me) => _write('me.json', me);

  /// Borra todo lo de esta cuenta en el teléfono (al cerrar sesión).
  Future<void> wipe() => _serial(() async {
    try {
      await root.delete(recursive: true);
    } on PathNotFoundException {
      // Ya no existía.
    }
  });
}
