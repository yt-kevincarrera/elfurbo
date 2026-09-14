import 'package:cloud_firestore/cloud_firestore.dart';

enum AttendanceStatus { yes, no, maybe }

/// Asistencia de un jugador a un partido (colección `attendance`).
/// El id del documento es `{matchId}_{uid}`.
class Attendance {
  const Attendance({
    required this.matchId,
    required this.uid,
    required this.status,
    this.updatedAt,
  });

  final String matchId;
  final String uid;
  final AttendanceStatus status;
  final DateTime? updatedAt;

  static String docId(String matchId, String uid) => '${matchId}_$uid';

  factory Attendance.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return Attendance(
      matchId: (d['matchId'] as String?) ?? '',
      uid: (d['uid'] as String?) ?? '',
      status: AttendanceStatus.values.firstWhere(
        (s) => s.name == d['status'],
        orElse: () => AttendanceStatus.maybe,
      ),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
