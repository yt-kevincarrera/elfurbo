/// Intención de asistir, marcada antes de la jornada.
enum AttendanceStatus { yes, no, maybe }

/// Asistencia de un jugador a una jornada.
///
/// Tiene dos datos distintos:
/// - [status]: la intención previa (Voy / Quizás / No voy). `null` = no la marcó.
/// - [played]: la presencia real, confirmada después de la jornada por el
///   propio jugador ("Jugué"), al poner goles, o por el staff al pasar lista.
///   `null` = todavía nadie lo confirmó.
///
/// Una vez jugada la jornada, solo la presencia real cuenta para partidos
/// jugados, rachas, logros, valoraciones y permisos de confirmar y votar.
class Attendance {
  const Attendance({
    required this.matchId,
    required this.uid,
    this.status,
    this.played,
    this.playedSetBy,
  });

  final String matchId;

  /// Id de miembro.
  final String uid;
  final AttendanceStatus? status;
  final bool? played;
  final String? playedSetBy;

  bool get isPresent => played == true;
  bool get isAbsent => played == false;
  bool get presenceUnknown => played == null;

  /// Una fila `attendance` de la vista local.
  factory Attendance.fromCloud(Map<String, dynamic> d) {
    final intent = d['intent'];
    return Attendance(
      matchId: (d['matchdayId'] as String?) ?? '',
      uid: (d['memberId'] as String?) ?? '',
      status: intent == null
          ? null
          : AttendanceStatus.values.firstWhere(
              (s) => s.name == intent,
              orElse: () => AttendanceStatus.maybe,
            ),
      played: d['played'] as bool?,
      playedSetBy: d['playedSetBy'] as String?,
    );
  }
}
