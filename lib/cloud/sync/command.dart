import 'dart:math';

final _random = Random.secure();

/// UUID v4 (el backend exige uuid en los ids de comandos y de lo que se crea).
String uuidV4() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Un cambio hecho en el teléfono, en la cola hasta que el servidor lo acepte
/// (spec §5). `clientAt` es la hora del teléfono cuando se hizo.
class Command {
  const Command({
    required this.id,
    required this.clubId,
    required this.type,
    required this.payload,
    required this.clientAt,
  });

  factory Command.create(
    String clubId,
    String type,
    Map<String, Object?> payload, {
    DateTime? now,
  }) => Command(
    id: uuidV4(),
    clubId: clubId,
    type: type,
    payload: payload,
    clientAt: (now ?? DateTime.now()).toUtc(),
  );

  final String id;
  final String clubId;
  final String type;
  final Map<String, Object?> payload;
  final DateTime clientAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'clubId': clubId,
    'type': type,
    'payload': payload,
    'clientAt': clientAt.toUtc().toIso8601String(),
  };

  factory Command.fromJson(Map<String, dynamic> j) => Command(
    id: j['id'] as String,
    clubId: j['clubId'] as String,
    type: j['type'] as String,
    payload: Map<String, Object?>.from(j['payload'] as Map),
    clientAt: DateTime.parse(j['clientAt'] as String),
  );
}

/// Un cambio que el servidor no aceptó, con su motivo, para "Cambios no aplicados".
class RejectedChange {
  const RejectedChange({
    required this.command,
    required this.code,
    required this.message,
  });

  final Command command;
  final String code;
  final String message;

  Map<String, Object?> toJson() => {
    'command': command.toJson(),
    'code': code,
    'message': message,
  };

  factory RejectedChange.fromJson(Map<String, dynamic> j) => RejectedChange(
    command: Command.fromJson(j['command'] as Map<String, dynamic>),
    code: j['code'] as String,
    message: j['message'] as String,
  );
}
