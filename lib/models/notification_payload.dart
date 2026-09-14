import 'dart:convert';

/// Qué representa una notificación (push de las Functions o local). Los
/// nombres del campo `type` coinciden con los que envían las Functions.
enum NotificationKind {
  update('update'),
  matchDay('match_day'),
  postMatch('post_match'),
  report('report'),
  reportStatus('report_status'),
  pendingUser('pending_user'),
  unknown('unknown');

  const NotificationKind(this.wire);

  /// Valor en JSON / `data.type` de FCM.
  final String wire;

  static NotificationKind fromWire(Object? value) =>
      NotificationKind.values.firstWhere(
        (k) => k.wire == value,
        orElse: () => NotificationKind.unknown,
      );
}

/// Datos mínimos para saber qué abrir al tocar una notificación.
class NotificationPayload {
  const NotificationPayload({required this.kind, this.matchId, this.tag});

  final NotificationKind kind;

  /// Jornada a abrir (report, match_day, post_match, report_status).
  final String? matchId;

  /// Tag de la release (update).
  final String? tag;

  bool get opensMatch => matchId != null && matchId!.isNotEmpty;

  /// Desde `RemoteMessage.data` de FCM.
  factory NotificationPayload.fromFcmData(Map<String, dynamic> data) =>
      NotificationPayload(
        kind: NotificationKind.fromWire(data['type']),
        matchId: data['matchId'] as String?,
        tag: data['tag'] as String?,
      );

  String encode() => jsonEncode({
    'type': kind.wire,
    if (matchId != null) 'matchId': matchId,
    if (tag != null) 'tag': tag,
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
      return NotificationPayload.fromFcmData(json);
    } on FormatException {
      return const NotificationPayload(kind: NotificationKind.unknown);
    }
  }
}
