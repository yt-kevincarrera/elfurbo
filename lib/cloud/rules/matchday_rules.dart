import 'package:timezone/timezone.dart' as tz;

/// Reglas puras de una jornada, idénticas a `backend/src/rules/matchday.ts`.
/// Las dos implementaciones pasan los mismos casos de
/// `shared-fixtures/matchday-rules.json`: si cambias una regla, cambia los
/// casos y ambos lados.
class MatchdayTimes {
  const MatchdayTimes({
    required this.startsAt,
    required this.durationMinutes,
    required this.status,
    required this.seasonClosed,
  });

  final DateTime startsAt;
  final int durationMinutes;

  /// `scheduled`, `cancelled`, `closed` o `reopened`.
  final String status;
  final bool seasonClosed;

  DateTime get endsAt => startsAt.add(Duration(minutes: durationMinutes));
}

/// Ya terminó: se pueden cargar goles, confirmar y votar. Una cancelada nunca "se jugó".
bool isPlayed(MatchdayTimes md, DateTime at) =>
    md.status != 'cancelled' && !at.isBefore(md.endsAt);

/// Todavía no terminó: se puede marcar la intención (Voy / Quizás / No voy).
bool acceptsIntent(MatchdayTimes md, DateTime at) =>
    md.status != 'cancelled' && at.isBefore(md.endsAt);

/// No acepta cambios: temporada cerrada, cancelada o cerrada a mano; o pasaron
/// `closeAfterHours` desde el inicio, salvo que la hayan reabierto.
bool isClosed(MatchdayTimes md, DateTime at, int closeAfterHours) {
  if (md.seasonClosed || md.status == 'cancelled' || md.status == 'closed') {
    return true;
  }
  if (md.status == 'reopened') return false;
  return !at.isBefore(md.startsAt.add(Duration(hours: closeAfterHours)));
}

/// Fecha local (AAAA-MM-DD) de un instante en una zona horaria: para detectar
/// jornadas duplicadas (del mismo día). Requiere `tz.initializeTimeZones()`.
String localDay(DateTime at, String timezone) {
  final local = tz.TZDateTime.from(at.toUtc(), tz.getLocation(timezone));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
