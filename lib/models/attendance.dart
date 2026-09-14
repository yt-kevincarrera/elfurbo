import 'package:cloud_firestore/cloud_firestore.dart';

/// Intención de asistir, marcada antes de la jornada.
enum AttendanceStatus { yes, no, maybe }

/// Asistencia de un jugador a una jornada (colección `attendance`).
/// El id del documento es `{matchId}_{uid}`.
///
/// Tiene dos datos distintos:
/// - [status]: la intención previa (Voy / Quizás / No voy).
/// - [played]: la presencia real, confirmada después de la jornada por el
///   propio jugador ("Jugué"), al cargar goles, o por el admin al pasar lista.
///   `null` = todavía nadie lo confirmó.
///
/// Una vez jugada la jornada, solo la presencia real cuenta para partidos
/// jugados, rachas, logros, valoraciones y permisos de confirmar y votar.
class Attendance {
  const Attendance({
    required this.matchId,
    required this.uid,
    required this.status,
    this.played,
    this.playedSetBy,
    this.updatedAt,
  });

  static const fieldPlayed = 'played';
  static const fieldPlayedSetBy = 'playedSetBy';

  final String matchId;
  final String uid;
  final AttendanceStatus status;
  final bool? played;
  final String? playedSetBy;
  final DateTime? updatedAt;

  bool get isPresent => played == true;
  bool get isAbsent => played == false;
  bool get presenceUnknown => played == null;

  static String docId(String matchId, String uid) => '${matchId}_$uid';

  factory Attendance.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Attendance.fromMap(doc.id, doc.data() ?? const <String, dynamic>{});

  factory Attendance.fromMap(String id, Map<String, dynamic> d) {
    return Attendance(
      matchId: (d['matchId'] as String?) ?? '',
      uid: (d['uid'] as String?) ?? '',
      status: AttendanceStatus.values.firstWhere(
        (s) => s.name == d['status'],
        orElse: () => AttendanceStatus.maybe,
      ),
      played: d[fieldPlayed] as bool?,
      playedSetBy: d[fieldPlayedSetBy] as String?,
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
