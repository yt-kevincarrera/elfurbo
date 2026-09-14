import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_messenger.dart';
import 'core/theme.dart';
import 'data/providers.dart';
import 'models/app_user.dart';
import 'ui/auth/login_screen.dart';
import 'ui/auth/pending_screen.dart';
import 'domain/reminders.dart';
import 'models/notification_payload.dart';
import 'services/local_notifications.dart';
import 'services/notification_router.dart';
import 'services/update_worker.dart';
import 'ui/shell/home_shell.dart';
import 'ui/widgets/update_dialog.dart';

class ElFurboApp extends StatelessWidget {
  const ElFurboApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'El Furbo',
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      locale: const Locale('es'),
      supportedLocales: const [Locale('es')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const AuthGate(),
    );
  }
}

/// Decide qué mostrar según la sesión: login, espera de aprobación o la app.
class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  String? _bootstrappedUid;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authStateProvider);
    final firebaseUser = auth.value;

    if (auth.isLoading && firebaseUser == null) return const _Splash();
    if (firebaseUser == null) {
      _bootstrappedUid = null;
      return const LoginScreen();
    }

    // Garantiza que exista el perfil (idempotente) una vez por sesión.
    if (_bootstrappedUid != firebaseUser.uid) {
      _bootstrappedUid = firebaseUser.uid;
      fireAndForget(ref.read(repoProvider).ensureUserDoc(firebaseUser));
    }

    final profile = ref.watch(currentUserProvider);
    final user = profile.value;
    if (user == null) {
      if (profile.hasError) {
        return _ErrorScreen(
          error: profile.error!,
          onRetry: () => ref.invalidate(currentUserProvider),
        );
      }
      return _ProfileWait(
        onRetry: () =>
            fireAndForget(ref.read(repoProvider).ensureUserDoc(firebaseUser)),
      );
    }

    switch (user.status) {
      case UserStatus.pending:
        return PendingScreen(user: user);
      case UserStatus.blocked:
        return PendingScreen(user: user, blocked: true);
      case UserStatus.active:
        return _ActiveSession(user: user);
    }
  }
}

class _ActiveSession extends ConsumerStatefulWidget {
  const _ActiveSession({required this.user});

  final AppUser user;

  @override
  ConsumerState<_ActiveSession> createState() => _ActiveSessionState();
}

class _ActiveSessionState extends ConsumerState<_ActiveSession> {
  @override
  void initState() {
    super.initState();
    NotificationRouter.onUpdateTapped = () => _checkForUpdates(force: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    NotificationRouter.onUpdateTapped = null;
    super.dispose();
  }

  Future<void> _start() async {
    ref.read(pushServiceProvider).register(widget.user.uid);
    await LocalNotifications.ensureInitialized(
      onTap: NotificationRouter.handle,
    );
    // Si la app se abrió tocando una notificación local, la atendemos ahora
    // que ya hay sesión y navigator.
    final launch = await LocalNotifications.consumeLaunchPayload();
    if (launch != null && launch.kind != NotificationKind.update) {
      NotificationRouter.handle(launch);
    }
    await _checkForUpdates(force: launch?.kind == NotificationKind.update);
    await UpdateWorker.schedule();
    _scheduleReminders();
    // Reprogramar cuando cambian las jornadas o mi intención.
    ref.listenManual(matchesProvider, (_, __) => _scheduleReminders());
    ref.listenManual(attendanceProvider, (_, __) => _scheduleReminders());
  }

  /// Busca una versión nueva (como mucho cada 12 h, o siempre con [force]).
  Future<void> _checkForUpdates({bool force = false}) async {
    final release = await ref
        .read(updateServiceProvider)
        .checkForUpdate(force: force)
        .catchError((_) => null);
    if (force) await LocalNotifications.cancelUpdate();
    if (release != null && mounted) {
      await showUpdateDialog(
        context,
        release: release,
        service: ref.read(updateServiceProvider),
      );
    }
  }

  /// Recordatorios locales de las próximas jornadas (09:00 y 22:00), según
  /// mi intención actual.
  void _scheduleReminders() {
    final matches = ref.read(matchesProvider).value;
    if (matches == null) return;
    final attendance = ref.read(attendanceProvider).value ?? const [];
    final mine = {
      for (final a in attendance)
        if (a.uid == widget.user.uid) a.matchId: a.status,
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

/// Espera mientras se crea el perfil. Si tarda (sin red, reglas, etc.),
/// ofrece reintentar en vez de quedarse colgada.
class _ProfileWait extends StatefulWidget {
  const _ProfileWait({required this.onRetry});

  final VoidCallback onRetry;

  @override
  State<_ProfileWait> createState() => _ProfileWaitState();
}

class _ProfileWaitState extends State<_ProfileWait> {
  static const _patience = Duration(seconds: 8);
  bool _slow = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_patience, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.sports_soccer,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _slow
                  ? 'Esto está tardando más de lo normal. Revisa tu conexión.'
                  : 'Preparando tu perfil…',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (_slow) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: widget.onRetry,
                child: const Text('Reintentar'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.sports_soccer,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 56),
              const SizedBox(height: 12),
              const Text(
                'No pudimos cargar tu perfil.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
            ],
          ),
        ),
      ),
    );
  }
}
