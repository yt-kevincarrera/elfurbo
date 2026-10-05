enum ReportStatus { pending, confirmed, rejected }

/// Goles y asistencias de un jugador en una jornada.
///
/// Cuenta (spec §2) si el staff lo confirmó o lo corrigió; si lo puso alguien
/// del staff o el servidor confía en los reportes ([autoConfirmed]), salvo
/// rechazo; o si lo confirman [confirmationsNeeded] compañeros que jugaron.
/// El staff puede rechazarlo (definitivo para el autor) o corregir los números.
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
    this.loadedBy,
    this.autoConfirmed = false,
    this.confirmationsNeeded = defaultConfirmationsNeeded,
  });

  static const int defaultConfirmationsNeeded = 2;

  final String matchId;

  /// Id de miembro del autor.
  final String uid;
  final int goals;
  final int assists;
  final String? note;

  /// Miembros que lo confirmaron (solo los que jugaron).
  final List<String> confirmations;
  final ReportStatus? adminStatus;

  /// Miembro del staff que corrigió los números (queda confirmado).
  final String? correctedBy;

  /// Quién lo puso (el autor o alguien del staff por él).
  final String? loadedBy;

  /// Cuenta sin confirmaciones: lo puso el staff o el servidor confía.
  final bool autoConfirmed;
  final int confirmationsNeeded;

  ReportStatus get status {
    if (adminStatus != null) return adminStatus!;
    if (autoConfirmed) return ReportStatus.confirmed;
    return confirmations.length >= confirmationsNeeded
        ? ReportStatus.confirmed
        : ReportStatus.pending;
  }

  bool get isConfirmed => status == ReportStatus.confirmed;
  bool get isPending => status == ReportStatus.pending;
  bool get isRejected => status == ReportStatus.rejected;
  bool get confirmedByAdmin => adminStatus == ReportStatus.confirmed;
  bool get correctedByAdmin => correctedBy != null;

  /// Confirmaciones que le faltan para contar (0 si ya cuenta).
  int get confirmationsMissing => isPending
      ? (confirmationsNeeded - confirmations.length).clamp(0, 99).toInt()
      : 0;

  /// El autor puede editar o borrar salvo que lo hayan rechazado: el
  /// rechazo es definitivo hasta que el staff quite su decisión.
  bool get authorCanEdit => !isRejected;
}
