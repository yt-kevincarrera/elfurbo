/// Mensajes para redes donde Google o GitHub no responden (por ejemplo Cuba,
/// donde las API de Firebase y GitHub rechazan las peticiones sin VPN).
library;

/// Texto corto que acompaña a los errores de red hacia Google o GitHub.
const String vpnHint =
    'Si estás en Cuba, activa la VPN: Google y GitHub no responden desde allí sin ella.';

/// true si el error parece un bloqueo de red o de región (403, servicio no
/// disponible, fallo de red) y no un problema de la cuenta.
bool looksLikeBlockedNetwork(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('403') ||
      text.contains('permission_denied') ||
      text.contains('permission-denied') ||
      text.contains('not available') ||
      text.contains('unavailable') ||
      text.contains('network-request-failed') ||
      text.contains('network_error') ||
      text.contains('failed host lookup') ||
      text.contains('connection') ||
      text.contains('timed out') ||
      text.contains('socketexception');
}
