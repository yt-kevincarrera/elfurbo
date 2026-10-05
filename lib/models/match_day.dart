/// Estado administrativo de una jornada.
///
/// - `scheduled`: normal; se cierra sola `closeAfterHours` después de empezar.
/// - `cancelled`: no se jugó.
/// - `closed`: el staff la cerró antes de tiempo.
/// - `reopened`: el staff la forzó abierta; solo se cierra a mano.
enum MatchStatus { scheduled, cancelled, closed, reopened }

/// Una jornada de un servidor. Los ids de jugadores son ids de miembro.
///
/// La jornada está "en curso" entre su hora y hora + duración, y "jugada"
/// después. "Cerrada" significa que ya no se aceptan goles, confirmaciones,
/// votos ni cambios de presencia.
class MatchDay {
  const MatchDay({
    required this.id,
    required this.date,
    required this.seasonId,
    required this.status,
    required this.createdBy,
    this.durationMinutes = defaultDurationMinutes,
    this.place,
    this.notes,
    this.teamA = const [],
    this.teamB = const [],
  });

  /// Las jornadas duran lo que quieran: sin duración, se reportan goles desde
  /// que empiezan y el "voy" se marca hasta la hora de inicio.
  static const int defaultDurationMinutes = 0;

  /// Por defecto de los servidores (`closeAfterHours`).
  static const int defaultCloseAfterHours = 72;

  final String id;
  final DateTime date;
  final int durationMinutes;
  final String seasonId;
  final MatchStatus status;
  final String createdBy;
  final String? place;
  final String? notes;
  final List<String> teamA;
  final List<String> teamB;

  DateTime get end => date.add(Duration(minutes: durationMinutes));

  bool get isCancelled => status == MatchStatus.cancelled;
  bool get isManuallyClosed => status == MatchStatus.closed;
  bool get isReopened => status == MatchStatus.reopened;
  bool get hasTeams => teamA.isNotEmpty || teamB.isNotEmpty;

  /// Todavía no empezó.
  bool isUpcoming(DateTime now) => !isCancelled && now.isBefore(date);

  /// Empezó y todavía no terminó.
  bool isInProgress(DateTime now) =>
      !isCancelled && !now.isBefore(date) && now.isBefore(end);

  /// Ya terminó (se pueden poner goles, confirmar y votar).
  bool isPlayed(DateTime now) => !isCancelled && !now.isBefore(end);

  /// Ya no acepta cambios: cancelada, cerrada a mano, pasaron
  /// `closeAfterHours` (salvo que la hayan reabierto) o su temporada está
  /// cerrada. Igual que `isClosed` de `cloud/rules/matchday_rules.dart`.
  bool isClosed(
    DateTime now, {
    bool seasonClosed = false,
    int closeAfterHours = defaultCloseAfterHours,
  }) {
    if (seasonClosed || isCancelled || isManuallyClosed) return true;
    if (isReopened) return false;
    return !now.isBefore(date.add(Duration(hours: closeAfterHours)));
  }

  /// Una fila `matchday` de la vista local.
  factory MatchDay.fromCloud(Map<String, dynamic> d) {
    final teams = (d['teams'] as Map?) ?? const {};
    return MatchDay(
      id: '${d['id']}',
      date: DateTime.tryParse('${d['startsAt']}')?.toLocal() ?? DateTime(2000),
      durationMinutes:
          (d['durationMinutes'] as num?)?.toInt() ?? defaultDurationMinutes,
      seasonId: (d['seasonId'] as String?) ?? '',
      status: MatchStatus.values.firstWhere(
        (s) => s.name == d['status'],
        orElse: () => MatchStatus.scheduled,
      ),
      createdBy: (d['createdBy'] as String?) ?? '',
      place: d['place'] as String?,
      notes: d['notes'] as String?,
      teamA: List<String>.from((teams['a'] as List?) ?? const []),
      teamB: List<String>.from((teams['b'] as List?) ?? const []),
    );
  }
}
