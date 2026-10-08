import 'package:flutter/material.dart';

import 'chalk.dart';

/// Los niveles de prestigio de un servidor (spec 2.0 §4), de más a menos.
enum Tier {
  official('Oficial', Icons.star, Chalk.yellow),
  verified('Verificado', Icons.verified, Chalk.green),
  established('Establecido', Icons.shield_outlined, Chalk.blue),
  casual('Casual', Icons.sports_soccer, Chalk.dim),
  fresh('Nuevo', Icons.fiber_new_outlined, Chalk.white);

  const Tier(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;

  /// Del valor del servidor (`new` es [fresh]: `new` no puede ser un nombre).
  static Tier parse(String? wire) => switch (wire) {
    'official' => official,
    'verified' => verified,
    'established' => established,
    'casual' => casual,
    _ => fresh,
  };

  /// Oficial o verificado: sus estadísticas "pesan".
  bool get trusted => this == official || this == verified;
}

/// La ficha del nivel: icono y nombre en su color de tiza. [compact] deja
/// solo el icono (para la barra).
class TierChip extends StatelessWidget {
  const TierChip(this.tier, {super.key, this.compact = false});

  TierChip.wire(String? wire, {Key? key, bool compact = false})
    : this(Tier.parse(wire), key: key, compact: compact);

  final Tier tier;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(tier.icon, size: compact ? 16 : 14, color: tier.color);
    if (compact) return Tooltip(message: tier.label, child: icon);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: ShapeDecoration(
        shape: ChalkBorder(
          radius: 8,
          side: BorderSide(color: tier.color.withValues(alpha: .8), width: 1.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 4),
          Text(
            tier.label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: tier.color),
          ),
        ],
      ),
    );
  }
}
