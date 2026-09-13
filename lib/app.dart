import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_messenger.dart';
import 'core/theme.dart';
import 'data/providers.dart';
import 'models/app_user.dart';
import 'ui/auth/login_screen.dart';
import 'ui/auth/pending_screen.dart';
import 'ui/shell/home_shell.dart';

class ElFurboApp extends StatelessWidget {
  const ElFurboApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'El Furbo',
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
      return const _Splash(message: 'Preparando tu perfil…');
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(pushServiceProvider).register(widget.user.uid);
    });
  }

  @override
  Widget build(BuildContext context) => const HomeShell();
}

class _Splash extends StatelessWidget {
  const _Splash({this.message});

  final String? message;

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
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(message!, style: Theme.of(context).textTheme.bodyMedium),
            ],
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
