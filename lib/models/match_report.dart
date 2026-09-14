import 'package:cloud_firestore/cloud_firestore.dart';

enum ReportStatus { pending, confirmed, rejected }

/// Goles y asistencias que un jugador reportó en un partido (colección `reports`).
/// El id del documento es `{matchId}_{uid}`.
///
/// Reglas de confirmación: queda confirmado si el admin lo confirma, o si dos
/// compañeros con presencia real lo confirman. El admin puede rechazarlo
/// (definitivo para el autor) o corregir los números (queda confirmado).
class MatchReport {
  const MatchReport({
    required this.matchId,
    required this.uid,
    required this.goals,
    required this.assists,
    this.note,
    this.confirmations = const [],
    this.adminStatus,
    this.correctedBy,
    this.updatedAt,
  });

  static const int confirmationsNeeded = 2;

  final String matchId;
  final String uid;
  final int goals;
  final int assists;
  final String? note;
  final List<String> confirmations;
  final ReportStatus? adminStatus;

  /// Uid del admin que corrigió los números (queda confirmado por él).
  final String? correctedBy;
  final DateTime? updatedAt;

  String get id => docId(matchId, uid);
  static String docId(String matchId, String uid) => '${matchId}_$uid';

  ReportStatus get status {
    if (adminStatus != null) return adminStatus!;
    return confirmations.length >= confirmationsNeeded
        ? ReportStatus.confirmed
        : ReportStatus.pending;
  }

  bool get isConfirmed => status == ReportStatus.confirmed;
  bool get isPending => status == ReportStatus.pending;
  bool get isRejected => status == ReportStatus.rejected;
  bool get confirmedByAdmin => adminStatus == ReportStatus.confirmed;
  bool get correctedByAdmin => correctedBy != null;

  /// El autor puede editar o borrar salvo que el admin lo haya rechazado: el
  /// rechazo es definitivo hasta que el admin quite su decisión.
  bool get authorCanEdit => !isRejected;

  factory MatchReport.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    final adminRaw = d['adminStatus'] as String?;
    return MatchReport(
      matchId: (d['matchId'] as String?) ?? '',
      uid: (d['uid'] as String?) ?? '',
      goals: (d['goals'] as num?)?.toInt() ?? 0,
      assists: (d['assists'] as num?)?.toInt() ?? 0,
      note: d['note'] as String?,
      confirmations: List<String>.from(
        (d['confirmations'] as List?) ?? const [],
      ),
      correctedBy: d['correctedBy'] as String?,
      adminStatus: adminRaw == null
          ? null
          : ReportStatus.values.firstWhere(
              (s) => s.name == adminRaw,
              orElse: () => ReportStatus.pending,
            ),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
