import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/achievements.dart';
import '../../domain/stats_engine.dart';
import '../../models/app_user.dart';
import '../matches/match_detail_screen.dart';
import '../stats/leaderboard_screen.dart';
import '../widgets/common.dart';
import '../widgets/player_avatar.dart';
import '../widgets/update_dialog.dart';

class PlayerProfileScreen extends ConsumerWidget {
  const PlayerProfileScreen({
    super.key,
    required this.uid,
    this.embedded = false,
  });

  final String uid;

  /// true cuando es la pestaña "Perfil" del shell (sin botón atrás, con logout).
  final bool embedded;

  static Future<void> open(BuildContext context, String uid) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => PlayerProfileScreen(uid: uid)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(usersByIdProvider)[uid];
    final myUid = ref.watch(myUidProvider);
    final isMe = uid == myUid;
    final stats = ref.watch(statsProvider);
    final allTime = ref.watch(allTimeStatsProvider);
    final s = stats.statsOf(uid);
    final lifetime = allTime.statsOf(uid);
    final achievements = Achievements.forPlayer(lifetime);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final periodLabel = ref.watch(seasonFilterLabelProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(isMe ? 'Mi perfil' : (user?.name ?? 'Jugador')),
        actions: [
          const SeasonSelector(),
          if (isMe)
            _ProfileMenu(onSignOut: () => _confirmSignOut(context, ref)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                PlayerAvatar(user: user, radius: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user?.name ?? 'Jugador',
                        style: text.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (user != null &&
                          user.nickname != null &&
                          user.nickname!.isNotEmpty)
                        Text(
                          user.displayName,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      Text(
                        [
                          if (user?.isAdmin ?? false) 'Admin',
                          '${Achievements.unlockedCount(lifetime)} logros',
                          if (lifetime.currentStreak > 1)
                            '🔥 ${lifetime.currentStreak} seguidos',
                        ].join(' · '),
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isMe)
                  IconButton(
                    tooltip: 'Cambiar apodo',
                    onPressed: () => _editNickname(context, ref, user),
                    icon: const Icon(Icons.edit_outlined),
                  ),
              ],
            ),
          ),
          SectionTitle(periodLabel),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.15,
              children: [
                StatTile(
                  label: 'Partidos',
                  value: '${s.matchesPlayed}',
                  icon: Icons.sports_soccer,
                ),
                StatTile(
                  label: 'Goles',
                  value: '${s.goals}',
                  icon: Icons.sports_score,
                  color: scheme.confirmed,
                ),
                StatTile(
                  label: 'Asistencias',
                  value: '${s.assists}',
                  icon: Icons.handshake_outlined,
                ),
                StatTile(
                  label: 'MVP',
                  value: '${s.mvps}',
                  icon: Icons.emoji_events,
                  color: scheme.mvpGold,
                ),
                StatTile(
                  label: 'Goles / partido',
                  value: Fmt.decimal(s.goalsPerMatch),
                  icon: Icons.speed,
                ),
                StatTile(
                  label: 'Mejor racha',
                  value: '${s.bestStreak}',
                  icon: Icons.local_fire_department,
                ),
              ],
            ),
          ),
          if (s.pendingGoals + s.pendingAssists > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                'Sin confirmar: ${Fmt.goals(s.pendingGoals)} y ${Fmt.assists(s.pendingAssists)}.',
                style: text.bodySmall?.copyWith(color: scheme.pending),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _RankChip(
                  label: 'Goleador',
                  position: stats.positionOf(uid, RankingKind.goals),
                ),
                _RankChip(
                  label: 'Asistidor',
                  position: stats.positionOf(uid, RankingKind.assists),
                ),
                _RankChip(
                  label: 'MVP',
                  position: stats.positionOf(uid, RankingKind.mvps),
                ),
              ],
            ),
          ),
          const SectionTitle('Evolución'),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 20, 0),
            child: _EvolutionChart(points: stats.evolution(uid)),
          ),
          const SectionTitle('Logros'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (final a in achievements) _AchievementRow(progress: a),
              ],
            ),
          ),
          const SectionTitle('Historial'),
          _History(uid: uid, stats: stats),
        ],
      ),
    );
  }

  Future<void> _editNickname(
    BuildContext context,
    WidgetRef ref,
    AppUser? user,
  ) async {
    final controller = TextEditingController(text: user?.nickname ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tu apodo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(
            hintText: 'Cómo te llaman en la cancha',
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result == null) return;
    fireAndForget(
      ref.read(repoProvider).updateNickname(uid, result),
      success: 'Apodo guardado',
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Cerrar sesión?'),
        content: const Text(
          'Si tenés cambios sin sincronizar, esperá a tener internet antes de salir.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Volver'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Salir'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(pushServiceProvider).dispose();
      await ref.read(authServiceProvider).signOut();
    }
  }
}

class _RankChip extends StatelessWidget {
  const _RankChip({required this.label, required this.position});

  final String label;
  final int? position;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = position != null && position! <= 3;
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        top ? Icons.emoji_events : Icons.tag,
        size: 16,
        color: top ? scheme.mvpGold : null,
      ),
      label: Text(position == null ? '$label: –' : '$label: $positionº'),
    );
  }
}

class _EvolutionChart extends StatelessWidget {
  const _EvolutionChart({required this.points});

  final List<EvolutionPoint> points;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (points.length < 2) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
        child: Text(
          'Con al menos dos partidos jugados aparece la curva de goles y asistencias.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final goals = [
      for (final p in points)
        FlSpot(p.matchIndex.toDouble(), p.cumulativeGoals.toDouble()),
    ];
    final assists = [
      for (final p in points)
        FlSpot(p.matchIndex.toDouble(), p.cumulativeAssists.toDouble()),
    ];
    final maxY = [...goals, ...assists].fold(0.0, (m, s) => s.y > m ? s.y : m);
    final labelEvery = (points.length / 4).ceil().clamp(1, 100);

    return Column(
      children: [
        SizedBox(
          height: 200,
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: maxY < 4 ? 4 : maxY * 1.1,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    getTitlesWidget: (v, meta) => v == v.roundToDouble()
                        ? Text(
                            v.toInt().toString(),
                            style: Theme.of(context).textTheme.labelSmall,
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: labelEvery.toDouble(),
                    getTitlesWidget: (v, meta) {
                      final i = v.round();
                      if (i < 0 || i >= points.length || i != v) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          Fmt.dayMonth(points[i].date),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots.map((s) {
                    final p = points[s.x.round()];
                    final isGoals = s.barIndex == 0;
                    return LineTooltipItem(
                      '${Fmt.dayMonth(p.date)}\n${isGoals ? 'Goles' : 'Asist.'}: ${s.y.toInt()}${isGoals && p.goals > 0 ? ' (+${p.goals})' : ''}${!isGoals && p.assists > 0 ? ' (+${p.assists})' : ''}',
                      TextStyle(
                        color: isGoals ? scheme.primary : scheme.tertiary,
                        fontSize: 12,
                      ),
                    );
                  }).toList(),
                ),
              ),
              lineBarsData: [
                _line(goals, scheme.primary),
                _line(assists, scheme.tertiary),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Legend(color: scheme.primary, label: 'Goles acumulados'),
            const SizedBox(width: 16),
            _Legend(color: scheme.tertiary, label: 'Asistencias acumuladas'),
          ],
        ),
      ],
    );
  }

  LineChartBarData _line(List<FlSpot> spots, Color color) => LineChartBarData(
    spots: spots,
    isCurved: false,
    color: color,
    barWidth: 3,
    dotData: FlDotData(show: spots.length <= 12),
    belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.08)),
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _AchievementRow extends StatelessWidget {
  const _AchievementRow({required this.progress});

  final AchievementProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final unlocked = progress.unlocked;
    final tierColor = switch (progress.tier) {
      0 => scheme.onSurfaceVariant,
      1 when progress.maxTier == 1 => scheme.confirmed,
      1 => const Color(0xFFB87333),
      2 => const Color(0xFF9E9E9E),
      _ => scheme.mvpGold,
    };
    final next = progress.nextThreshold;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Opacity(
              opacity: unlocked ? 1 : 0.35,
              child: Text(
                progress.def.emoji,
                style: const TextStyle(fontSize: 28),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          progress.def.title,
                          style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text(
                        progress.tierLabel,
                        style: text.labelSmall?.copyWith(
                          color: tierColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    progress.def.description(
                      next ?? progress.def.thresholds.last,
                    ),
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (next != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress.progress,
                        minHeight: 5,
                        color: tierColor,
                      ),
                    ),
                    Text(
                      '${progress.current} / $next',
                      style: text.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _History extends ConsumerWidget {
  const _History({required this.uid, required this.stats});

  final String uid;
  final StatsEngine stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final matches = stats.playedMatches.reversed
        .where((m) => stats.playersInMatch(m.id).contains(uid))
        .toList();
    if (matches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'Sin partidos jugados en este período.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Column(
      children: [
        for (final m in matches)
          Builder(
            builder: (context) {
              final report = (stats.reportsByMatch[m.id] ?? const [])
                  .where((r) => r.uid == uid)
                  .firstOrNull;
              final mvp = (stats.mvpsByMatch[m.id] ?? const []).contains(uid);
              return ListTile(
                dense: true,
                onTap: () => MatchDetailScreen.open(context, m.id),
                leading: Icon(
                  mvp ? Icons.emoji_events : Icons.sports_soccer,
                  color: mvp ? scheme.mvpGold : scheme.onSurfaceVariant,
                ),
                title: Text(Fmt.short(m.date)),
                subtitle: Text(
                  report == null
                      ? 'Sin reporte'
                      : '${Fmt.goals(report.goals)} · ${Fmt.assists(report.assists)}${mvp ? ' · MVP' : ''}',
                ),
                trailing: report == null
                    ? null
                    : ReportStatusChip(report: report, compact: true),
              );
            },
          ),
      ],
    );
  }
}

/// Menú de "Mi perfil": versión instalada, buscar actualizaciones y salir.
class _ProfileMenu extends ConsumerWidget {
  const _ProfileMenu({required this.onSignOut});

  final VoidCallback onSignOut;

  Future<void> _checkForUpdates(BuildContext context, WidgetRef ref) async {
    final service = ref.read(updateServiceProvider);
    showMessage('Buscando actualizaciones…');
    try {
      final release = await service.checkForUpdate(force: true);
      if (!context.mounted) return;
      if (release == null) {
        showMessage('Ya tenés la última versión');
        return;
      }
      await showUpdateDialog(context, release: release, service: service);
    } catch (e) {
      showError('No se pudo consultar GitHub: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider).value;
    return PopupMenuButton<String>(
      tooltip: 'Más opciones',
      onSelected: (value) {
        switch (value) {
          case 'update':
            _checkForUpdates(context, ref);
          case 'logout':
            onSignOut();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Text('El Furbo ${version ?? ''}'.trim()),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'update',
          child: ListTile(
            leading: Icon(Icons.system_update),
            title: Text('Buscar actualizaciones'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: 'logout',
          child: ListTile(
            leading: Icon(Icons.logout),
            title: Text('Cerrar sesión'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}
