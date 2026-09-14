import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../models/app_user.dart';
import '../widgets/player_avatar.dart';

/// Pantalla de espera: el usuario entró pero el admin todavía no lo aprobó
/// (o lo bloqueó).
class PendingScreen extends ConsumerWidget {
  const PendingScreen({super.key, required this.user, this.blocked = false});

  final AppUser user;
  final bool blocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PlayerAvatar(user: user, radius: 40),
              const SizedBox(height: 16),
              Text(user.displayName, style: text.titleLarge),
              const SizedBox(height: 24),
              Icon(
                blocked ? Icons.block : Icons.hourglass_top,
                size: 56,
                color: blocked ? scheme.error : scheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                blocked ? 'Tu cuenta está bloqueada' : 'Esperando aprobación',
                style: text.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                blocked
                    ? 'Habla con el admin del grupo si crees que es un error.'
                    : 'Avísale al admin del grupo que ya entraste. Cuando te apruebe, esta pantalla se actualiza sola.',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: () => ref.read(authServiceProvider).signOut(),
                icon: const Icon(Icons.logout),
                label: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
