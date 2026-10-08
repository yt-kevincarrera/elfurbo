import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../cloud/api/admin_api.dart';
import '../../cloud/state/providers.dart';
import '../../cloud/ui/errors.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import '../widgets/tier_chip.dart';

const _labels = {
  'age': 'Antigüedad',
  'activity': 'Actividad',
  'size': 'Jugadores por jornada',
  'validation': 'Cómo se validan los goles',
  'accounts': 'Jugadores con cuenta',
  'network': 'Juegan también en otros servidores',
  'rejected': 'Reportes rechazados',
  'goals': 'Goles fuera de lo normal',
};

/// El prestigio del servidor (spec 2.0 §4): su nivel, la puntuación por partes
/// y qué le falta para subir. Lo calcula el servidor cada pocos minutos, así
/// que necesita señal.
class PrestigeSection extends ConsumerWidget {
  const PrestigeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final club = ref.watch(currentClubProvider);
    if (club == null) return const SizedBox.shrink();
    final prestige = ref.watch(prestigeProvider(club.id));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          'Prestigio',
          trailing: IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(prestigeProvider(club.id)),
          ),
        ),
        prestige.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: AppLoading(size: 36)),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              describeError(e),
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          data: (p) => _PrestigeCard(prestige: p),
        ),
      ],
    );
  }
}

class _PrestigeCard extends StatelessWidget {
  const _PrestigeCard({required this.prestige});

  final Prestige prestige;

  @override
  Widget build(BuildContext context) {
    final p = prestige;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final tier = Tier.parse(p.tier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TierChip(tier),
              const SizedBox(width: 12),
              if (p.computedAt != null)
                Text('${p.score} de 100', style: text.titleMedium),
            ],
          ),
          const SizedBox(height: 6),
          Text(switch (tier) {
            Tier.official =>
              'Servidor oficial: sus estadísticas pesan lo más que se puede.',
            Tier.verified =>
              'Sus estadísticas pesan casi como las de un oficial.',
            Tier.established =>
              'Con 70 puntos y "Con confirmación" pasa a Verificado.',
            Tier.casual => 'Con 40 puntos pasa a Establecido.',
            Tier.fresh =>
              p.newReason ??
                  'Todavía no se ha calculado: vuelve en unos minutos.',
          }, style: text.bodySmall),
          const SizedBox(height: 12),
          for (final part in p.parts) _PartRow(part: part),
          if (p.computedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                'Calculado ${DateFormat("d MMM, HH:mm", 'es').format(p.computedAt!)}. '
                'Se actualiza cada pocos minutos.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _PartRow extends StatelessWidget {
  const _PartRow({required this.part});

  final PrestigePart part;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    String points(double x) =>
        x == x.roundToDouble() ? '${x.toInt()}' : x.toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _labels[part.key] ?? part.key,
                  style: text.bodyMedium,
                ),
              ),
              Text(
                part.penalty
                    ? points(part.points)
                    : '${points(part.points)} / ${part.max}',
                style: text.labelLarge?.copyWith(
                  color: part.penalty ? scheme.error : null,
                ),
              ),
            ],
          ),
          if (!part.penalty) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: part.max == 0 ? 0 : (part.points / part.max).clamp(0, 1),
              borderRadius: BorderRadius.circular(4),
            ),
          ],
          if (part.hint != null) ...[
            const SizedBox(height: 4),
            Text(
              part.hint!,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
