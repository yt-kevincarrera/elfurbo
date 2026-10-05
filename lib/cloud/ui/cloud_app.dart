import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/theme.dart';
import '../../ui/widgets/chalk.dart';
import '../state/providers.dart';
import 'auth_screens.dart';
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
/// a la app y cada 2 minutos mientras está abierta (spec §5).
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
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _sync());
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sync();
  }

  void _sync() {
    final cloud = ref.read(cloudProvider);
    if (cloud.session != null) unawaited(cloud.sync());
  }

  @override
  Widget build(BuildContext context) {
    // Al cerrarse la sesión (salir, borrar la cuenta o un 401) se vuelve a la raíz:
    // no puede quedar encima un diálogo o una pantalla de la sesión anterior.
    ref.listen(sessionProvider, (prev, next) {
      if (prev?.value != null && next.value == null) {
        rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      }
    });
    final session = ref.watch(sessionProvider);
    if (session.isLoading && !session.hasValue) {
      return const Scaffold(body: LoadingView());
    }
    return session.value == null ? const WelcomeScreen() : const CloudHome();
  }
}
