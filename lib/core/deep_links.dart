import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Enlaces con los que se abre la app: `elfurbo://invite/CODIGO` (el botón
/// "Abrir en El Furbo" de la página de invitación). Los pasa `MainActivity`
/// por un canal propio; el Navigator de Flutter no los ve.
abstract final class DeepLinks {
  static const _channel = MethodChannel('app.elfurbo/links');

  /// Código de invitación que llegó por enlace y falta atender. Lo atiende
  /// `CloudGate`: con sesión abre "Entrar con código"; sin sesión, primero la cuenta.
  static final pendingInvite = ValueNotifier<String?>(null);

  /// Servidor público que llegó por enlace (`elfurbo://club/ID`, el botón
  /// "Pedir entrar" de su página): se abre su ficha del directorio.
  static final pendingClub = ValueNotifier<String?>(null);

  /// Llamar una vez al arrancar (con el binding ya inicializado).
  static Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link') handle('${call.arguments}');
    });
    try {
      final initial = await _channel.invokeMethod<String>('initial');
      if (initial != null) handle(initial);
    } on MissingPluginException {
      // Fuera de Android (tests): no hay enlaces.
    } on PlatformException {
      // Igual: sin enlace de arranque.
    }
  }

  static void handle(String link) {
    final code = inviteCode(link);
    if (code != null) pendingInvite.value = code;
    final club = clubId(link);
    if (club != null) pendingClub.value = club;
  }

  /// El id de un enlace a un servidor (`elfurbo://club/ID` o la página
  /// `https://…/s/ID`), o null si no es uno.
  static String? clubId(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final id = switch (uri.scheme) {
      'elfurbo' when uri.host == 'club' && segments.length == 1 => segments[0],
      'https' ||
      'http' when segments.length == 2 && segments[0] == 's' => segments[1],
      _ => null,
    };
    if (id == null || !RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(id)) {
      return null;
    }
    return id;
  }

  /// El código de un enlace de invitación (`elfurbo://invite/CODIGO` o la
  /// página `https://…/i/CODIGO`), o null si no es uno.
  static String? inviteCode(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final code = switch (uri.scheme) {
      'elfurbo' when uri.host == 'invite' && segments.length == 1 =>
        segments[0],
      'https' ||
      'http' when segments.length == 2 && segments[0] == 'i' => segments[1],
      _ => null,
    };
    if (code == null || !RegExp(r'^[A-Za-z0-9-]{4,32}$').hasMatch(code)) {
      return null;
    }
    return code.toUpperCase();
  }
}
