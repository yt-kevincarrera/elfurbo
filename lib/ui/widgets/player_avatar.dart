import 'package:flutter/material.dart';

import '../../models/app_user.dart';

class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar({super.key, required this.user, this.radius = 20});

  final AppUser? user;
  final double radius;

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
    final photo = user?.photoUrl;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      foregroundImage: photo != null && photo.isNotEmpty
          ? NetworkImage(photo)
          : null,
      onForegroundImageError: photo != null ? (_, __) {} : null,
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: radius * 0.8,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
