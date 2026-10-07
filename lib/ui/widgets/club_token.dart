import 'package:flutter/material.dart';

import 'chalk.dart';

const _connectors = {'y', 'e', 'de', 'del', 'la', 'el', 'los', 'las'};

/// Las iniciales de un servidor: "Unción y Fuego" es UF, no UY.
String clubInitials(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty && w[0].toUpperCase() != w[0].toLowerCase())
    .where((w) => !_connectors.contains(w.toLowerCase()))
    .take(2)
    .map((w) => w[0].toUpperCase())
    .join();

/// La ficha de un servidor: sus iniciales en su color. Un torneo lleva una
/// copita en la esquina.
class ClubToken extends StatelessWidget {
  const ClubToken({
    super.key,
    required this.name,
    required this.color,
    this.size = 40,
    this.tournament = false,
  });

  final String name;

  /// Índice de la paleta (`Chalk.clubColors`).
  final int color;
  final double size;
  final bool tournament;

  @override
  Widget build(BuildContext context) {
    final token = ChalkToken(
      label: clubInitials(name),
      color: Chalk.club(color),
      filled: true,
      size: size,
    );
    if (!tournament) return token;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        token,
        Positioned(
          right: -4,
          bottom: -4,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              color: Chalk.board,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.emoji_events,
              size: size * .38,
              color: Chalk.yellow,
            ),
          ),
        ),
      ],
    );
  }
}
