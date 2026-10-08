import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/api/api_client.dart';
import '../../cloud/api/players_api.dart';
import '../../cloud/state/providers.dart';
import '../../cloud/ui/errors.dart';
import '../../cloud/ui/home_screens.dart';
import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../widgets/club_token.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import '../widgets/tier_chip.dart';

/// Lo que un jugador hizo en todos sus servidores (spec 2.0 §5), con el nivel
/// de cada uno: así sus números no se miran en bruto. Es lo único del perfil
/// que necesita señal.
class GlobalStatsSection extends ConsumerWidget {
  const GlobalStatsSection({
    super.key,
    required this.userId,
    this.isMe = false,
  });

  final String userId;
  final bool isMe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(globalProfileProvider(userId));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          'En toda la app',
          trailing: IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(globalProfileProvider(userId)),
          ),
        ),
        // Con lo último que se trajo se sigue viendo aunque falle al actualizar.
        if (profile.value case final p?)
          _Body(profile: p, isMe: isMe)
        else if (profile.hasError)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              profile.error is OfflineException
                  ? 'Sin conexión: esto se ve cuando haya señal.'
                  : describeError(profile.error!),
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: AppLoading(size: 36)),
          ),
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.profile, required this.isMe});

  final GlobalProfile profile;
  final bool isMe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = profile;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Jornadas',
                  value: '${p.all.played}',
                  icon: Icons.sports_soccer,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatTile(
                  label: 'Goles',
                  value: '${p.all.goals}',
                  icon: Icons.sports_score,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _explainIndex(context),
                  child: StatTile(
                    label: 'Índice Furbo',
                    value: p.index == null ? '—' : Fmt.decimal(p.index!),
                    icon: Icons.insights,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Text(
            p.trusted.played == 0
                ? 'Todavía no tiene jornadas en servidores oficiales o verificados.'
                : 'En servidores oficiales o verificados: '
                      '${Fmt.plural(p.trusted.played, 'jornada', 'jornadas')}, '
                      '${Fmt.goals(p.trusted.goals)} y '
                      '${Fmt.assists(p.trusted.assists)}.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        if (p.trophies.isNotEmpty) ...[
          const SectionTitle('Vitrina'),
          GroupedSection(
            children: [for (final t in p.trophies) TrophyTile(trophy: t)],
          ),
        ],
        if (p.memberships.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text(
              'Todavía no hay jornadas que enseñar.',
              style: text.bodyMedium,
            ),
          )
        else
          GroupedSection(
            children: [
              for (final m in p.memberships) _MembershipTile(membership: m),
            ],
          ),
        if (isMe && p.showPrivateStats != null)
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            title: const Text('Enseñar lo de mis servidores privados'),
            subtitle: const Text(
              'A quien no es de esos servidores le salen sin el nombre.',
            ),
            value: p.showPrivateStats!,
            onChanged: (v) async {
              try {
                await ref.read(playersApiProvider).setShowPrivateStats(v);
                ref.invalidate(globalProfileProvider(p.userId));
                showMessage(
                  v
                      ? 'Listo, se ven sin el nombre del servidor'
                      : 'Listo, ya no se ven',
                );
              } catch (e) {
                showError(e);
              }
            },
          ),
      ],
    );
  }

  void _explainIndex(BuildContext context) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Índice Furbo'),
      content: const Text(
        'Lo que aporta por jornada: goles, más 0,7 por asistencia y 1,5 por '
        'MVP. Cada temporada pesa según el nivel del servidor: oficial 100 %, '
        'verificado 80 %, establecido 50 %, casual y nuevo 25 %.\n\n'
        'Así un número inflado en un servidor de amigos no vale lo mismo que '
        'uno hecho donde todo se confirma. Sale a partir de 5 jornadas '
        'ponderadas.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Entendido'),
        ),
      ],
    ),
  );
}

class _MembershipTile extends StatelessWidget {
  const _MembershipTile({required this.membership});

  final GlobalMembership membership;

  @override
  Widget build(BuildContext context) {
    final m = membership;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final name = m.name ?? 'Servidor privado';
    return ExpansionTile(
      leading: m.hidden
          ? const CircleAvatar(child: Icon(Icons.lock_outline))
          : ClubToken(
              name: name,
              color: m.color,
              tournament: m.kind == 'tournament',
            ),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TierChip.wire(m.tier),
          Text(
            '${Fmt.plural(m.totals.played, 'jornada', 'jornadas')} · '
            '${m.totals.goals} G · ${m.totals.assists} A',
            style: text.bodySmall,
          ),
        ],
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        if (!m.hidden)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(roleLabel(m.role), style: text.labelMedium),
          ),
        if (!m.counted)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Solo lo ves tú: este servidor no comparte sus estadísticas '
              '(o está suspendido), así que no cuenta en tus totales.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        for (final period in m.periods)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(period.name, style: text.titleSmall)),
                    TierChip.wire(period.tier),
                    if (period.frozen)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Tooltip(
                          message: 'Temporada cerrada: el nivel de entonces',
                          child: Icon(
                            Icons.ac_unit,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
                Text(
                  '${period.stats.played} PJ · ${period.stats.goals} G · '
                  '${period.stats.assists} A · ${period.stats.mvps} MVP'
                  '${period.hatTricks > 0 ? ' · ${period.hatTricks} hat-tricks' : ''}',
                  style: text.bodySmall,
                ),
                if (period.flag)
                  Text(
                    '⚠️ Promedio fuera de lo normal en este servidor',
                    style: text.bodySmall?.copyWith(color: scheme.error),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Un trofeo de la vitrina: "🏆 Campeón · Copa Verano".
class TrophyTile extends StatelessWidget {
  const TrophyTile({super.key, required this.trophy});

  final Trophy trophy;

  static const labels = {
    'champion': ('🏆', 'Campeón'),
    'runner_up': ('🥈', 'Subcampeón'),
    'third': ('🥉', 'Tercer lugar'),
    'top_scorer': ('👟', 'Bota de oro'),
    'top_assists': ('🎯', 'Más asistencias'),
    'best_player': ('⭐', 'Mejor jugador'),
    'fair_play': ('🤝', 'Fair play'),
  };

  @override
  Widget build(BuildContext context) {
    final (emoji, label) = labels[trophy.kind] ?? ('🏅', 'Premio');
    return ListTile(
      leading: Text(emoji, style: const TextStyle(fontSize: 28)),
      title: Text('$label · ${trophy.tournament}'),
      subtitle: trophy.teamName == null && trophy.value == null
          ? null
          : Text(
              [
                ?trophy.teamName,
                if (trophy.value != null && trophy.kind == 'top_scorer')
                  Fmt.goals(trophy.value!),
                if (trophy.value != null && trophy.kind == 'top_assists')
                  Fmt.assists(trophy.value!),
              ].join(' · '),
            ),
    );
  }
}

/// El perfil global de cualquiera (desde el directorio o una solicitud).
class GlobalPlayerScreen extends ConsumerWidget {
  const GlobalPlayerScreen({super.key, required this.userId, this.displayName});

  final String userId;
  final String? displayName;

  static Future<void> open(
    BuildContext context,
    String userId, {
    String? displayName,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          GlobalPlayerScreen(userId: userId, displayName: displayName),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(globalProfileProvider(userId)).value;
    final me = ref.watch(meProvider).value?.user.id;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final name = profile?.displayName ?? displayName ?? 'Jugador';
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            leading: CircleAvatar(
              radius: 28,
              child: Text(
                name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                style: text.titleLarge,
              ),
            ),
            title: Text(
              name,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            subtitle: profile == null
                ? null
                : Text(
                    '@${profile.username}'
                    '${profile.since == null ? '' : ' · en El Furbo desde ${Fmt.monthYear(profile.since!)}'}',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
          ),
          GlobalStatsSection(userId: userId, isMe: userId == me),
        ],
      ),
    );
  }
}
