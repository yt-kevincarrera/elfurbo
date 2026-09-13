import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/stats_engine.dart';
import '../../models/app_user.dart';
import '../../models/match_day.dart';
import '../../services/share_service.dart';
import '../widgets/common.dart';

/// Resumen del partido como tarjeta para compartir por WhatsApp.
class SummaryTab extends ConsumerStatefulWidget {
  const SummaryTab({super.key, required this.match});

  final MatchDay match;

  @override
  ConsumerState<SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends ConsumerState<SummaryTab> {
  final _cardKey = GlobalKey();
  bool _sharing = false;

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      await ShareService.shareBoundary(
        _cardKey,
        fileName:
            'elfurbo_${Fmt.dateOnly(widget.match.date).replaceAll('/', '-')}.png',
        text: 'Resumen del ${Fmt.short(widget.match.date)} ⚽',
      );
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.match.isPlayed(DateTime.now())) {
      return const EmptyState(
        icon: Icons.image_outlined,
        title: 'El resumen se arma después del partido',
      );
    }
    final users = ref.watch(usersByIdProvider);
    final allTime = ref.watch(allTimeStatsProvider);
    final summary = allTime.summary(widget.match.id);
    final season = ref
        .watch(seasonsProvider)
        .value
        ?.where((s) => s.id == widget.match.seasonId)
        .firstOrNull;
    final seasonStats = StatsEngine(
      matches: ref.watch(matchesProvider).value ?? const [],
      reports: ref.watch(reportsProvider).value ?? const [],
      votes: ref.watch(mvpVotesProvider).value ?? const [],
      attendance: ref.watch(attendanceProvider).value ?? const [],
      seasonId: widget.match.seasonId.isEmpty ? null : widget.match.seasonId,
    );
    final pending = ref
        .watch(reportsForMatchProvider(widget.match.id))
        .where((r) => r.isPending)
        .length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (pending > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Hay $pending ${pending == 1 ? 'reporte pendiente' : 'reportes pendientes'}: no aparecen hasta que los confirmen.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.pending,
              ),
            ),
          ),
        Center(
          child: RepaintBoundary(
            key: _cardKey,
            child: MatchSummaryCard(
              match: widget.match,
              summary: summary,
              users: users,
              seasonName: season?.name,
              topScorers: seasonStats
                  .ranking(RankingKind.goals)
                  .take(3)
                  .toList(),
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _sharing ? null : _share,
          icon: _sharing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.share),
          label: const Text('Compartir por WhatsApp'),
        ),
      ],
    );
  }
}

class MatchSummaryCard extends StatelessWidget {
  const MatchSummaryCard({
    super.key,
    required this.match,
    required this.summary,
    required this.users,
    required this.topScorers,
    this.seasonName,
  });

  final MatchDay match;
  final MatchSummary summary;
  final Map<String, AppUser> users;
  final List<PlayerStats> topScorers;
  final String? seasonName;

  String _name(String uid) => users[uid]?.name ?? 'Jugador';

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0E2A12);
    const accent = Color(0xFF7CD67C);
    const gold = Color(0xFFFFC94D);
    final scorers = summary.confirmedReports.where((r) => r.goals > 0).toList();
    final assisters =
        summary.confirmedReports.where((r) => r.assists > 0).toList()
          ..sort((a, b) => b.assists.compareTo(a.assists));

    return Container(
      width: 360,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF0E2A12), Color(0xFF16421C)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontFamily: 'Roboto',
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.sports_soccer, color: accent, size: 28),
                const SizedBox(width: 8),
                const Text(
                  'EL FURBO',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    fontSize: 18,
                    color: accent,
                  ),
                ),
                const Spacer(),
                if (seasonName != null)
                  Text(
                    seasonName!,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              Fmt.weekdayLong(match.date),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            if (match.place != null)
              Text(match.place!, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 4),
            Text(
              '${summary.players.length} jugadores · ${Fmt.goals(summary.totalGoals)}',
              style: const TextStyle(color: Colors.white70),
            ),
            const Divider(color: Colors.white24, height: 24),
            if (summary.mvps.isNotEmpty) ...[
              Row(
                children: [
                  const Icon(Icons.emoji_events, color: gold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'MVP: ${summary.mvps.map(_name).join(' y ')}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: gold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            const Text(
              'GOLES',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: Colors.white70,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 4),
            if (scorers.isEmpty)
              const Text(
                'Ninguno confirmado todavía',
                style: TextStyle(
                  color: Colors.white54,
                  fontStyle: FontStyle.italic,
                ),
              )
            else
              for (final r in scorers)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _name(r.uid),
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                      Text(
                        '⚽' * r.goals.clamp(0, 6) +
                            (r.goals > 6 ? ' ×${r.goals}' : ''),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
            if (assisters.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'ASISTENCIAS',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  color: Colors.white70,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                assisters
                    .map((r) => '${_name(r.uid)} (${r.assists})')
                    .join(' · '),
                style: const TextStyle(fontSize: 13),
              ),
            ],
            if (topScorers.isNotEmpty) ...[
              const Divider(color: Colors.white24, height: 24),
              Text(
                'TABLA ${seasonName?.toUpperCase() ?? ''}'.trim(),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  color: Colors.white70,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 4),
              for (var i = 0; i < topScorers.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        child: Text(
                          '${i + 1}.',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                      Expanded(child: Text(_name(topScorers[i].uid))),
                      Text(
                        '${topScorers[i].goals} g · ${topScorers[i].assists} a',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
