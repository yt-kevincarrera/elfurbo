import 'package:flutter/material.dart';

import '../core/app_messenger.dart';
import '../models/notification_payload.dart';
import '../ui/matches/match_detail_screen.dart';
import '../ui/shell/home_shell.dart';
import '../ui/superadmin/superadmin_screen.dart';

/// Traduce el payload de una notificación (push o local) a navegación.
///
/// Solo navega si hay una sesión activa montada (el `Navigator` global
/// existe). Si la app todavía está arrancando, `_ActiveSession` vuelve a
/// llamar con el payload de arranque cuando está lista.
class NotificationRouter {
  NotificationRouter._();

  /// Quien quiera reaccionar a "hay una actualización" (forzar el chequeo)
  /// se registra aquí; lo hace `_ActiveSession`.
  static VoidCallback? onUpdateTapped;

  /// Cambia al servidor de la notificación (lo registra `ClubSession`).
  /// Devuelve false si ya no soy miembro.
  static bool Function(String clubId)? onSelectClub;

  static void handle(NotificationPayload payload) {
    final clubId = payload.clubId;
    if (clubId != null &&
        payload.kind != NotificationKind.clubRequest &&
        !(onSelectClub?.call(clubId) ?? true)) {
      return;
    }
    switch (payload.kind) {
      case NotificationKind.update:
        onUpdateTapped?.call();
      case NotificationKind.pendingUser:
        requestedHomeTab.value = HomeShell.adminTab;
      case NotificationKind.matchDay:
      case NotificationKind.postMatch:
      case NotificationKind.report:
      case NotificationKind.reportStatus:
        // Tras cambiar de servidor, la jornada se abre cuando ya está a la vista.
        if (payload.opensMatch) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _openMatch(payload.matchId!),
          );
        }
      case NotificationKind.clubRequest:
        final nav = rootNavigatorKey.currentState;
        nav?.popUntil((route) => route.isFirst);
        nav?.push(
          MaterialPageRoute<void>(builder: (_) => const SuperadminScreen()),
        );
      case NotificationKind.club:
        rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
      case NotificationKind.unknown:
        break;
    }
  }

  static void _openMatch(String matchId) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) {
      debugPrint('Notificaciones: sin navigator para abrir $matchId');
      return;
    }
    // Volvemos a la raíz para no apilar detalles si ya había uno abierto.
    rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    MatchDetailScreen.open(context, matchId);
  }
}
