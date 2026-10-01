typedef Row = Map<String, Object?>;

/// Todo lo que el teléfono sabe de un servidor: el último estado recibido del
/// servidor por entidad (`member`, `season`, `matchday`, …) y el cursor del pull.
///
/// Es el "estado del servidor". La vista que ve la interfaz se calcula encima,
/// aplicando los comandos pendientes (ver `reducers.dart`).
class ClubData {
  ClubData({
    required this.clubId,
    this.cursor = 0,
    Map<String, Map<String, Row>>? entities,
  }) : entities = entities ?? {};

  final String clubId;
  int cursor;
  final Map<String, Map<String, Row>> entities;

  Map<String, Row> table(String entity) =>
      entities.putIfAbsent(entity, () => {});

  Row? one(String entity, String id) => entities[entity]?[id];

  Iterable<Row> all(String entity) => entities[entity]?.values ?? const [];

  /// El servidor en sí (nombre, estado, ajustes).
  Row? get club => one('club', clubId);

  /// Copia profunda: para calcular la vista sin tocar el estado del servidor.
  ClubData copy() => ClubData(
    clubId: clubId,
    cursor: cursor,
    entities: {
      for (final e in entities.entries)
        e.key: {for (final r in e.value.entries) r.key: _deepCopy(r.value)},
    },
  );

  /// Aplica una respuesta del pull para este servidor (foto completa o cambios).
  void applyPull(Map<String, dynamic> pull) {
    if (pull['snapshot'] == true) entities.clear();
    final upserts = (pull['upserts'] as Map?) ?? const {};
    for (final e in upserts.entries) {
      final t = table(e.key as String);
      for (final row in (e.value as List)) {
        final r = Map<String, Object?>.from(row as Map);
        t['${r['id']}'] = r;
      }
    }
    final deletes = (pull['deletes'] as Map?) ?? const {};
    for (final e in deletes.entries) {
      final t = table(e.key as String);
      for (final id in (e.value as List)) {
        t.remove('$id');
      }
    }
    cursor = (pull['cursor'] as num).toInt();
  }

  Map<String, Object?> toJson() => {
    'clubId': clubId,
    'cursor': cursor,
    'entities': entities,
  };

  factory ClubData.fromJson(Map<String, dynamic> j) => ClubData(
    clubId: j['clubId'] as String,
    cursor: (j['cursor'] as num).toInt(),
    entities: {
      for (final e in (j['entities'] as Map).entries)
        e.key as String: {
          for (final r in (e.value as Map).entries)
            r.key as String: Map<String, Object?>.from(r.value as Map),
        },
    },
  );
}

Row _deepCopy(Row r) => {for (final e in r.entries) e.key: _copyValue(e.value)};

Object? _copyValue(Object? v) {
  if (v is Map) return {for (final e in v.entries) e.key: _copyValue(e.value)};
  if (v is List) return [for (final x in v) _copyValue(x)];
  return v;
}
