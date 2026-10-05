import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_messenger.dart';
import 'data/providers.dart';
import 'domain/reminders.dart';
import 'models/notification_payload.dart';
import 'services/local_notifications.dart';
import 'services/notification_router.dart';
import 'services/update_worker.dart';
import 'ui/shell/home_shell.dart';
import 'ui/widgets/update_dialog.dart';

/// Con sesión y un servidor elegido: la app del servidor (jornadas, tabla,
/// perfil y admin). Al abrirse busca actualizaciones, programa los
/// recordatorios de las próximas jornadas y atiende la notificación con la
/// que se abrió la app.
class ClubSession extends ConsumerStatefulWidget {
  const ClubSession({super.key});

  @override
  ConsumerState<ClubSession> createState() => _ClubSessionState();
}

class _ClubSessionState extends ConsumerState<ClubSession> {
  @override
  void initState() {
    super.initState();
    NotificationRouter.onUpdateTapped = () => _checkForUpdates(force: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startSafely());
  }

  @override
  void dispose() {
    NotificationRouter.onUpdateTapped = null;
    super.dispose();
  }

  /// Notificaciones y actualizaciones son extras: si fallan, la app sigue.
  Future<void> _startSafely() async {
    try {
      await _start();
    } catch (e) {
      debugPrint('ClubSession: arranque incompleto: $e');
    }
  }

  Future<void> _start() async {
    await LocalNotifications.ensureInitialized(
      onTap: NotificationRouter.handle,
    );
    // Si la app se abrió tocando una notificación local, se atiende ahora
    // que ya hay sesión y navigator.
    final launch = await LocalNotifications.consumeLaunchPayload();
    if (!mounted) return;
    if (launch != null && launch.kind != NotificationKind.update) {
      NotificationRouter.handle(launch);
    }
    await _checkForUpdates(force: launch?.kind == NotificationKind.update);
    await UpdateWorker.schedule();
    if (!mounted) return;
    _scheduleReminders();
    // Reprogramar cuando cambian las jornadas o mi intención.
    ref.listenManual(matchesProvider, (_, _) => _scheduleReminders());
    ref.listenManual(attendanceProvider, (_, _) => _scheduleReminders());
  }

  /// Busca una versión nueva (como mucho cada 12 h, o siempre con [force]).
  Future<void> _checkForUpdates({bool force = false}) async {
    final service = ref.read(updateServiceProvider);
    final release = await service
        .checkForUpdate(force: force)
        .catchError((_) => null);
    if (force) await LocalNotifications.cancelUpdate();
    if (release != null && mounted) {
      await showUpdateDialog(context, release: release, service: service);
    }
  }

  /// Recordatorios locales de las próximas jornadas (09:00 y 22:00) del
  /// servidor elegido, según mi intención actual.
  void _scheduleReminders() {
    final matches = ref.read(matchesProvider).value;
    if (matches == null) return;
    final attendance = ref.read(attendanceProvider).value ?? const [];
    final me = ref.read(myUidProvider);
    final mine = {
      for (final a in attendance)
        if (a.uid == me) a.matchId: a.status,
    };
    fireAndForget(
      LocalNotifications.scheduleReminders(
        plannedReminders(matches, mine, DateTime.now()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const HomeShell();
}
