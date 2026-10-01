import 'dart:convert';
import 'dart:io';

import 'club_data.dart';
import 'command.dart';

/// Lo que el teléfono guarda de una cuenta, en archivos JSON dentro de su
/// carpeta privada: un archivo por servidor, la cola de cambios pendientes, los
/// cambios rechazados y la última respuesta de `/me` (para arrancar sin señal).
///
/// Cada cuenta tiene su carpeta: si en el teléfono entra otra persona, no ve
/// nada de la anterior. Cada escritura es atómica (archivo temporal + rename).
class LocalStore {
  LocalStore(this.root);

  final Directory root;

  File _file(String name) => File('${root.path}${Platform.pathSeparator}$name');

  Future<Object?> _read(String name) async {
    final f = _file(name);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } on FormatException {
      // Un archivo a medias (corte de luz) no tumba la app: se descarta.
      return null;
    }
  }

  Future<void> _write(String name, Object? value) async {
    await root.create(recursive: true);
    final tmp = _file('$name.tmp');
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

  Future<void> deleteClub(String clubId) async {
    final f = _file(_clubFile(clubId));
    if (await f.exists()) await f.delete();
  }

  Future<List<String>> clubIds() async {
    if (!await root.exists()) return const [];
    final ids = <String>[];
    await for (final e in root.list()) {
      final name = e.uri.pathSegments.last;
      if (name.startsWith('club-') && name.endsWith('.json')) {
        ids.add(name.substring(5, name.length - 5));
      }
    }
    return ids;
  }

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
  Future<void> wipe() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}
