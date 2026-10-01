import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../state/providers.dart';
import 'auth_screens.dart';
import 'home_screens.dart';

/// La app de la 1.0 (backend propio). Se arranca con `lib/main_cloud.dart`.
class CloudApp extends StatelessWidget {
  const CloudApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'El Furbo',
      debugShowCheckedModeBanner: false,
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
    final session = ref.watch(sessionProvider);
    if (session.isLoading && !session.hasValue) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return session.value == null ? const WelcomeScreen() : const CloudHome();
  }
}
