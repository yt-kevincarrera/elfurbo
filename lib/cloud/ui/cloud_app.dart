import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/deep_links.dart';
import '../../core/theme.dart';
import '../../ui/directory/directory_screen.dart';
import '../../ui/widgets/chalk.dart';
import '../../services/sync_worker.dart';
import '../state/providers.dart';
import 'auth_screens.dart';
import 'clubs_screens.dart';
import 'home_screens.dart';
import '../../ui/widgets/expressive.dart';

/// La app (backend propio). Se arranca con `lib/main.dart`.
class CloudApp extends StatelessWidget {
  const CloudApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'El Furbo',
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      builder: (context, child) => ChalkDust(child: child!),
      locale: const Locale('es'),
      supportedLocales: const [Locale('es')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const CloudGate(),
    );
  }
}

/// Sin sesión: bienvenida. Con sesión: el inicio, y sincroniza al abrir, al volver
/// a la app y cada 2 minutos mientras está abierta (spec §5). Con la app cerrada
/// sigue WorkManager: cada ~15 min y, si quedan cambios por enviar al salir, en
/// cuanto haya conexión.
class CloudGate extends ConsumerStatefulWidget {
  const CloudGate({super.key});

  @override
  ConsumerState<CloudGate> createState() => _CloudGateState();
}

class _CloudGateState extends ConsumerState<CloudGate>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(minutes: 2), (_) {
      _sync();
      // Mientras siga a la vista, el de segundo plano lo sabe.
      if (ref.read(cloudProvider).visible) SyncWorker.markVisible(true);
    });
    SyncWorker.markVisible(true);
    DeepLinks.pendingInvite.addListener(_onInvite);
    DeepLinks.pendingClub.addListener(_onClub);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onInvite());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onClub());
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    DeepLinks.pendingInvite.removeListener(_onInvite);
    DeepLinks.pendingClub.removeListener(_onClub);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (ref.read(cloudProvider).visible != visible) {
      ref.read(cloudProvider).visible = visible;
      unawaited(SyncWorker.markVisible(visible));
    }
    if (state == AppLifecycleState.resumed) _sync();
    if (state == AppLifecycleState.paused) unawaited(_flushLater());
  }

  void _sync() {
    final cloud = ref.read(cloudProvider);
    if (cloud.session == null) return;
    unawaited(cloud.sync());
    unawaited(ref.read(syncWorkerProvider).schedule());
  }

  /// Al salir con cambios por enviar: que salgan en cuanto haya conexión.
  Future<void> _flushLater() async {
    final engine = ref.read(cloudProvider).engine;
    final worker = ref.read(syncWorkerProvider);
    if (engine == null || (await engine.store.readOutbox()).isEmpty) return;
    await worker.flushWhenOnline();
  }

  /// Llegó un enlace de invitación: con sesión, "Entrar con código" ya relleno;
  /// sin sesión, primero la cuenta (el código espera hasta que entre).
  void _onInvite() {
    final code = DeepLinks.pendingInvite.value;
    final context = rootNavigatorKey.currentContext;
    if (code == null || context == null || !mounted) return;
    final nav = rootNavigatorKey.currentState!..popUntil((r) => r.isFirst);
    if (ref.read(cloudProvider).session != null) {
      DeepLinks.pendingInvite.value = null;
      showJoinWithCode(context, initialCode: code);
    } else {
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const RegisterScreen(fromInvite: true),
        ),
      );
    }
  }

  /// Llegó un enlace a un servidor público: con sesión, su ficha del
  /// directorio; sin sesión, espera a que entre.
  void _onClub() {
    final id = DeepLinks.pendingClub.value;
    final context = rootNavigatorKey.currentContext;
    if (id == null || context == null || !mounted) return;
    if (ref.read(cloudProvider).session == null) return;
    DeepLinks.pendingClub.value = null;
    rootNavigatorKey.currentState!.popUntil((r) => r.isFirst);
    DirectoryClubScreen.open(context, id);
  }

  @override
  Widget build(BuildContext context) {
    // Al cerrarse la sesión (salir, borrar la cuenta o un 401) se vuelve a la raíz:
    // no puede quedar encima un diálogo o una pantalla de la sesión anterior.
    ref.listen(sessionProvider, (prev, next) {
      if (prev?.value != null && next.value == null) {
        rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      }
      // Entró con un enlace de invitación pendiente: ahora sí.
      if (prev?.value == null && next.value != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _onInvite());
        WidgetsBinding.instance.addPostFrameCallback((_) => _onClub());
      }
    });
    final session = ref.watch(sessionProvider);
    if (session.isLoading && !session.hasValue) {
      return const Scaffold(body: LoadingView());
    }
    return session.value == null ? const WelcomeScreen() : const CloudHome();
  }
}
