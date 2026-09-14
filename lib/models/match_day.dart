import 'package:cloud_firestore/cloud_firestore.dart';

/// Estado administrativo de una jornada.
///
/// - `scheduled`: normal; se cierra sola 72 h después de empezar.
/// - `cancelled`: no se jugó.
/// - `closed`: el admin la cerró antes de tiempo.
/// - `reopened`: el admin la forzó abierta; solo se cierra a mano.
enum MatchStatus { scheduled, cancelled, closed, reopened }

/// Una jornada (colección `matches`; el nombre interno se conserva).
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
    this.createdAt,
  });

  static const int defaultDurationMinutes = 120;
  static const Duration autoCloseAfter = Duration(hours: 72);

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
  final DateTime? createdAt;

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

  /// Ya terminó (se pueden cargar goles, confirmar y votar).
  bool isPlayed(DateTime now) => !isCancelled && !now.isBefore(end);

  /// Ya no acepta cambios: cancelada, cerrada por el admin, pasaron las 72 h
  /// (salvo que el admin la haya reabierto) o su temporada está cerrada.
  bool isClosed(DateTime now, {bool seasonClosed = false}) {
    if (seasonClosed || isCancelled || isManuallyClosed) return true;
    if (isReopened) return false;
    return !now.isBefore(date.add(autoCloseAfter));
  }

  factory MatchDay.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    final teams = (d['teams'] as Map<String, dynamic>?) ?? const {};
    return MatchDay(
      id: doc.id,
      date: (d['date'] as Timestamp?)?.toDate() ?? DateTime(2000),
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
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
