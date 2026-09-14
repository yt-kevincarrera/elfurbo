import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/attendance.dart';
import '../../models/match_day.dart';
import '../widgets/common.dart';
import 'match_detail_screen.dart';
import 'match_form_sheet.dart';

class MatchesScreen extends ConsumerWidget {
  const MatchesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matchesAsync = ref.watch(matchesProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final now = DateTime.now();

    return Scaffold(
      appBar: AppBar(title: const Text('Jornadas')),
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              onPressed: () => showMatchFormSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('Nueva jornada'),
            )
          : null,
      body: matchesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'No se pudieron cargar las jornadas',
          subtitle: '$e',
        ),
        data: (matches) {
          if (matches.isEmpty) {
            return EmptyState(
              icon: Icons.sports_soccer,
              title: 'Todavía no hay jornadas',
              subtitle: isAdmin
                  ? 'Crea la primera con el botón de abajo.'
                  : 'Cuando el admin cargue una jornada, aparece aquí.',
            );
          }
          // Próximas: todo lo que todavía no terminó (incluye en curso y las
          // canceladas con fecha futura). Jugadas: el resto, más recientes
          // primero (la lista ya viene ordenada descendente).
          bool isFuture(MatchDay m) => m.end.isAfter(now);
          final upcoming = matches.where(isFuture).toList()
            ..sort((a, b) => a.date.compareTo(b.date));
          final played = matches.where((m) => !isFuture(m)).toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (upcoming.isNotEmpty) ...[
                const SectionTitle('Próximas'),
                for (final m in upcoming) _UpcomingMatchCard(match: m),
              ],
              if (played.isNotEmpty) ...[
                const SectionTitle('Jugadas'),
                for (final m in played) _PlayedMatchCard(match: m),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _UpcomingMatchCard extends ConsumerWidget {
  const _UpcomingMatchCard({required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attendance = ref.watch(attendanceForMatchProvider(match.id));
    final myUid = ref.watch(myUidProvider);
    final mine = attendance[myUid]?.status;
    final going = attendance.values
        .where((a) => a.status == AttendanceStatus.yes)
        .length;
    final maybe = attendance.values
        .where((a) => a.status == AttendanceStatus.maybe)
        .length;
    final now = DateTime.now();
    final inProgress = match.isInProgress(now);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => MatchDetailScreen.open(context, match.id),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${Fmt.relative(match.date)} · ${Fmt.time(match.date)}',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        decoration: match.isCancelled
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                  if (match.isCancelled)
                    _Hint(
                      text: 'Cancelada',
                      color: scheme.onSurfaceVariant,
                      icon: Icons.event_busy,
                    )
                  else if (inProgress)
                    _Hint(
                      text: 'En curso',
                      color: scheme.primary,
                      icon: Icons.play_circle_outline,
                    ),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
              Text(
                [
                  Fmt.dayMonth(match.date),
                  if (match.place != null) match.place!,
                ].join(' · '),
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (!match.isCancelled) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.groups,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$going van${maybe > 0 ? ' · $maybe quizás' : ''}',
                      style: text.bodyMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AttendanceStatus>(
                    emptySelectionAllowed: true,
                    showSelectedIcon: false,
                    selected: {if (mine != null) mine},
                    onSelectionChanged: (sel) {
                      if (sel.isEmpty) return;
                      fireAndForget(
                        ref
                            .read(repoProvider)
                            .setAttendance(match.id, myUid, sel.first),
                      );
                    },
                    segments: const [
                      ButtonSegment(
                        value: AttendanceStatus.yes,
                        label: Text('Voy'),
                        icon: Icon(Icons.check),
                      ),
                      ButtonSegment(
                        value: AttendanceStatus.maybe,
                        label: Text('Quizás'),
                        icon: Icon(Icons.question_mark),
                      ),
                      ButtonSegment(
                        value: AttendanceStatus.no,
                        label: Text('No voy'),
                        icon: Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayedMatchCard extends ConsumerWidget {
  const _PlayedMatchCard({required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(allTimeStatsProvider);
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final reports = ref.watch(reportsForMatchProvider(match.id));
    final closed = ref.watch(matchClosedProvider(match.id));
    final myReport = reports.where((r) => r.uid == myUid).firstOrNull;
    final pendingOthers = reports
        .where((r) => r.uid != myUid && r.isPending)
        .length;
    final summary = stats.summary(match.id);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final iPlayed = summary.players.contains(myUid);

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: () => MatchDetailScreen.open(context, match.id),
        leading: CircleAvatar(
          backgroundColor: match.isCancelled
              ? scheme.surfaceContainerHighest
              : scheme.primaryContainer,
          child: Icon(
            match.isCancelled ? Icons.event_busy : Icons.sports_soccer,
            color: match.isCancelled
                ? scheme.onSurfaceVariant
                : scheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          Fmt.short(match.date),
          style: text.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            decoration: match.isCancelled ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: match.isCancelled
            ? const Text('Cancelada')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${summary.players.length} jugadores · ${Fmt.goals(summary.totalGoals)}'
                    '${summary.mvps.isNotEmpty ? ' · MVP ${summary.mvps.map((u) => users[u]?.name ?? '?').join(', ')}' : ''}',
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (closed)
                        _Hint(
                          text: 'Cerrada',
                          color: scheme.onSurfaceVariant,
                          icon: Icons.lock_outline,
                        ),
                      if (myReport != null)
                        ReportStatusChip(report: myReport, compact: true),
                      if (myReport == null && iPlayed && !closed)
                        _Hint(
                          text: 'Carga tus goles',
                          color: scheme.pending,
                          icon: Icons.edit,
                        ),
                      if (pendingOthers > 0 && iPlayed && !closed)
                        _Hint(
                          text: '$pendingOthers para confirmar',
                          color: scheme.primary,
                          icon: Icons.how_to_vote,
                        ),
                    ],
                  ),
                ],
              ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text, required this.color, required this.icon});

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
