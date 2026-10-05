import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import 'expressive.dart';

/// Iniciales del jugador sobre una forma de Material. El mismo jugador
/// siempre tiene la misma forma y el mismo color.
class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar({
    super.key,
    required this.user,
    this.radius = 20,
    this.avoid,
  });

  final AppUser? user;
  final double radius;

  /// Color de fondo sobre el que va: si coincide con el suyo, usa otro para
  /// no desaparecer.
  final Color? avoid;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = user?.name ?? '?';
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();
    final id = user?.uid ?? name;
    final palettes = [
      (scheme.primaryContainer, scheme.onPrimaryContainer),
      (scheme.secondaryContainer, scheme.onSecondaryContainer),
      (scheme.tertiaryContainer, scheme.onTertiaryContainer),
    ];
    var (bg, fg) = palettes[AppShapes.hashOf(id) % palettes.length];
    if (bg == avoid) (bg, fg) = (scheme.surface, scheme.onSurface);
    return ShapeBadge(
      shape: AppShapes.forId(id),
      color: bg,
      size: radius * 2.2,
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: TextStyle(
          color: fg,
          fontSize: radius * 0.8,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
