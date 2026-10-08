import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// El código de asistencia de una jornada (spec 2.0 §8.1): 6 cifras que
/// cambian cada 5 minutos, TOTP con HMAC-SHA256 sobre el secreto del
/// servidor. Igual que backend/src/rules/checkin.ts: los dos pasan
/// shared-fixtures/checkin.json.
const checkinWindow = Duration(minutes: 5);

/// El código de la ventana de [at] (o la de al lado, con [offset]).
String checkinCode(String secretHex, DateTime at, {int offset = 0}) {
  final counter =
      at.millisecondsSinceEpoch ~/ checkinWindow.inMilliseconds + offset;
  final msg = ByteData(8)..setUint64(0, counter);
  final mac = Hmac(
    sha256,
    _hexToBytes(secretHex),
  ).convert(msg.buffer.asUint8List()).bytes;
  // Truncado dinámico (RFC 4226).
  final o = mac.last & 0x0f;
  final bin =
      ((mac[o] & 0x7f) << 24) |
      (mac[o + 1] << 16) |
      (mac[o + 2] << 8) |
      mac[o + 3];
  return (bin % 1000000).toString().padLeft(6, '0');
}

/// Lo que le queda al código de ahora antes de cambiar.
Duration checkinRemaining(DateTime at) {
  final ms = checkinWindow.inMilliseconds;
  return Duration(milliseconds: ms - at.millisecondsSinceEpoch % ms);
}

/// "Estoy aquí" solo cerca de la jornada: 3 horas antes del inicio hasta 3
/// después del final, como comprueba el servidor.
bool checkinOpen(DateTime start, DateTime end, DateTime now) =>
    !now.isBefore(start.subtract(const Duration(hours: 3))) &&
    !now.isAfter(end.add(const Duration(hours: 3)));

Uint8List _hexToBytes(String hex) => Uint8List.fromList([
  for (var i = 0; i + 1 < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);
