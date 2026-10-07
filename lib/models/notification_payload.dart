import 'dart:convert';

/// Qué representa una notificación (todas son locales: las calcula el teléfono
/// con lo que trae el sync, ver `alerts.dart`).
enum NotificationKind {
  update('update'),
  matchDay('match_day'),
  postMatch('post_match'),
  report('report'),
  reportStatus('report_status'),
  pendingUser('pending_user'),

  /// Un servidor mío (aprobado o rechazado): abre ese servidor.
  club('club'),

  /// Superadmin: solicitudes de servidor por revisar.
  clubRequest('club_request'),
  unknown('unknown');

  const NotificationKind(this.wire);

  /// Valor en el JSON del payload.
  final String wire;

  static NotificationKind fromWire(Object? value) =>
      NotificationKind.values.firstWhere(
        (k) => k.wire == value,
        orElse: () => NotificationKind.unknown,
      );
}

/// Datos mínimos para saber qué abrir al tocar una notificación.
class NotificationPayload {
  const NotificationPayload({
    required this.kind,
    this.matchId,
    this.tag,
    this.clubId,
  });

  final NotificationKind kind;

  /// Servidor al que pertenece (se cambia a él antes de abrir la jornada).
  final String? clubId;

  /// Jornada a abrir (report, match_day, post_match, report_status).
  final String? matchId;

  /// Tag de la release (update).
  final String? tag;

  bool get opensMatch => matchId != null && matchId!.isNotEmpty;

  factory NotificationPayload.fromJson(Map<String, dynamic> data) =>
      NotificationPayload(
        kind: NotificationKind.fromWire(data['type']),
        matchId: data['matchId'] as String?,
        tag: data['tag'] as String?,
        clubId: data['clubId'] as String?,
      );

  String encode() => jsonEncode({
    'type': kind.wire,
    if (matchId != null) 'matchId': matchId,
    if (tag != null) 'tag': tag,
    if (clubId != null) 'clubId': clubId,
  });

  /// Tolera null y texto que no sea JSON (devuelve `unknown`).
  static NotificationPayload decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const NotificationPayload(kind: NotificationKind.unknown);
    }
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        return const NotificationPayload(kind: NotificationKind.unknown);
      }
      return NotificationPayload.fromJson(json);
    } on FormatException {
      return const NotificationPayload(kind: NotificationKind.unknown);
    }
  }
}
