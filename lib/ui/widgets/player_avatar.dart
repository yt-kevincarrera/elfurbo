import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import 'chalk.dart';
import 'expressive.dart';

/// El jugador como ficha de pizarra: un aro de tiza con sus iniciales. El
/// mismo jugador siempre tiene el mismo color de tiza.
class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar({
    super.key,
    required this.user,
    this.radius = 20,
    this.filled = false,
  });

  final AppUser? user;
  final double radius;

  /// Ficha llena (los que van, el que destaca).
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final name = user?.name ?? '?';
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();
    final id = user?.uid ?? name;
    return ChalkToken(
      label: initials.isEmpty ? '?' : initials,
      color: Chalk.tokens[AppShapes.hashOf(id) % Chalk.tokens.length],
      size: radius * 2.1,
      filled: filled,
      dashed: user?.isGuest ?? false,
    );
  }
}
