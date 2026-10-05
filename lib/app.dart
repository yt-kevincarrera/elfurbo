import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/providers.dart';
import 'domain/reminders.dart';
import 'models/notification_payload.dart';
import 'services/local_notifications.dart';
import 'services/notification_router.dart';
import 'services/update_worker.dart';
import 'ui/shell/home_shell.dart';
import 'ui/widgets/update_dialog.dart';

/// Recordatorios de las próximas jornadas del servidor elegido (09:00 y
/// 22:00), según mi intención. Se recalcula cuando cambian jornadas o asistencia.
final _reminderPlanProvider = Provider<List<PlannedReminder>>((ref) {
  final matches = ref.watch(matchesProvider).value ?? const [];
  final attendance = ref.watch(attendanceProvider).value ?? const [];
  final me = ref.watch(myUidProvider);
  return plannedReminders(matches, {
    for (final a in attendance)
      if (a.uid == me) a.matchId: a.status,
  }, DateTime.now());
});

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
    _debounce?.cancel();
    _reminders?.close();
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
    // Los recordatorios primero: el aviso de actualización puede quedarse
    // abierto un rato.
    _reminders = ref.listenManual(
      _reminderPlanProvider,
      (_, plan) => _scheduleReminders(plan),
      fireImmediately: true,
    );
    await _checkForUpdates(force: launch?.kind == NotificationKind.update);
    await UpdateWorker.schedule();
  }

  ProviderSubscription<List<PlannedReminder>>? _reminders;

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

  Timer? _debounce;
  Future<void> _scheduling = Future.value();
  String? _scheduled;

  /// Reprograma los recordatorios cuando cambia el plan: con un respiro (la
  /// vista cambia varias veces seguidas al sincronizar), uno detrás de otro
  /// (los ids son por posición, dos a la vez se pisarían) y solo si cambió algo.
  void _scheduleReminders(List<PlannedReminder> plan) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
      final key = [
        for (final r in plan) '${r.id}|${r.at.toIso8601String()}|${r.matchId}',
      ].join(',');
      if (key == _scheduled) return;
      _scheduled = key;
      _scheduling = _scheduling
          .then((_) => LocalNotifications.scheduleReminders(plan))
          .catchError((Object e) => debugPrint('Recordatorios: $e'));
    });
  }

  @override
  Widget build(BuildContext context) => const HomeShell();
}
