import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/app_update.dart';
import '../domain/reminders.dart';
import '../models/notification_payload.dart';

/// Notificaciones locales: canales, avisos inmediatos (actualización,
/// jugadores pendientes, reportes por confirmar) y recordatorios programados.
/// Funciona también en el isolate del worker de segundo plano.
class LocalNotifications {
  LocalNotifications._();

  /// Canal de los push de las Cloud Functions (coincide con el manifest).
  static const channelDefault = 'elfurbo_default';
  static const channelUpdates = 'elfurbo_updates';
  static const channelReminders = 'elfurbo_reminders';

  static const idUpdate = 4242;
  static const idPendingUsers = 4300;
  static const idReportsBase = 4400;

  static const _color = Color(0xFFD4AF37);
  static const _icon = '@drawable/ic_notification';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static void Function(NotificationPayload)? _onTap;

  /// Inicializa el plugin, crea los canales y configura la zona horaria.
  /// [onTap] recibe el payload cuando el usuario toca una notificación con la
  /// app viva (en frío se usa [consumeLaunchPayload]).
  static Future<void> ensureInitialized({
    void Function(NotificationPayload)? onTap,
  }) async {
    if (onTap != null) _onTap = onTap;
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_icon),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = NotificationPayload.decode(response.payload);
        _onTap?.call(payload);
      },
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          channelDefault,
          'El Furbo',
          description: 'Jornadas, reportes y aprobaciones del grupo',
          importance: Importance.high,
        ),
      );
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          channelUpdates,
          'Actualizaciones',
          description: 'Avisos de nuevas versiones de la app',
          importance: Importance.defaultImportance,
        ),
      );
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          channelReminders,
          'Recordatorios',
          description: 'Día de jornada y carga de goles',
          importance: Importance.high,
        ),
      );
    }
    await _initTimeZone();
    _initialized = true;
  }

  static Future<void> _initTimeZone() async {
    try {
      tzdata.initializeTimeZones();
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (e) {
      debugPrint('Notificaciones: zona horaria por defecto ($e)');
    }
  }

  static NotificationDetails _details(
    String channelId,
    String channelName, {
    Importance importance = Importance.high,
  }) => NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      channelName,
      importance: importance,
      priority: importance == Importance.high
          ? Priority.high
          : Priority.defaultPriority,
      color: _color,
      icon: _icon,
    ),
  );

  // ------------------------------------------------------------- inmediatas

  static Future<void> showUpdateAvailable(AppRelease release) async {
    await ensureInitialized();
    await _plugin.show(
      id: idUpdate,
      title: 'Nueva versión de El Furbo',
      body:
          'Ya está la ${release.version}. Toca para actualizar (en Cuba, con VPN).',
      notificationDetails: _details(
        channelUpdates,
        'Actualizaciones',
        importance: Importance.defaultImportance,
      ),
      payload: NotificationPayload(
        kind: NotificationKind.update,
        tag: release.tag,
      ).encode(),
    );
  }

  static Future<void> showPendingUsers(int count) async {
    await ensureInitialized();
    await _plugin.show(
      id: idPendingUsers,
      title: count == 1
          ? 'Un jugador espera aprobación'
          : '$count jugadores esperan aprobación',
      body: 'Entra a Admin para aprobarlos.',
      notificationDetails: _details(channelDefault, 'El Furbo'),
      payload: const NotificationPayload(
        kind: NotificationKind.pendingUser,
      ).encode(),
    );
  }

  static Future<void> showReportsToConfirm(String matchId, int count) async {
    await ensureInitialized();
    await _plugin.show(
      id: idReportsBase + (matchId.hashCode.abs() % 100),
      title: count == 1
          ? 'Tienes un reporte para confirmar'
          : 'Tienes $count reportes para confirmar',
      body: 'Tus compañeros cargaron goles. ¿Es verdad?',
      notificationDetails: _details(channelDefault, 'El Furbo'),
      payload: NotificationPayload(
        kind: NotificationKind.report,
        matchId: matchId,
      ).encode(),
    );
  }

  static Future<void> cancelUpdate() async {
    await ensureInitialized();
    await _plugin.cancel(id: idUpdate);
  }

  // ---------------------------------------------------------- recordatorios

  /// Reemplaza todos los recordatorios programados por [reminders].
  static Future<void> scheduleReminders(List<PlannedReminder> reminders) async {
    await ensureInitialized();
    await cancelReminders();
    for (final r in reminders) {
      try {
        await _plugin.zonedSchedule(
          id: r.id,
          title: r.title,
          body: r.body,
          scheduledDate: tz.TZDateTime.from(r.at, tz.local),
          notificationDetails: _details(channelReminders, 'Recordatorios'),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: NotificationPayload(
            kind: NotificationKind.matchDay,
            matchId: r.matchId,
          ).encode(),
        );
      } catch (e) {
        debugPrint('Notificaciones: no se pudo programar ${r.id}: $e');
      }
    }
  }

  static Future<void> cancelReminders() async {
    await ensureInitialized();
    for (var i = 0; i < 2 * maxReminderMatches; i++) {
      await _plugin.cancel(id: reminderIdBase + i);
    }
  }

  // ------------------------------------------------------------- arranque

  /// Payload de la notificación que abrió la app (una sola vez), o null.
  static Future<NotificationPayload?> consumeLaunchPayload() async {
    await ensureInitialized();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final raw = details.notificationResponse?.payload;
    if (raw == null) return null;
    return NotificationPayload.decode(raw);
  }
}
