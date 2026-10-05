import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/attendance.dart';
import '../../models/app_user.dart';
import '../../models/match_day.dart';
import '../widgets/common.dart';
import '../widgets/player_avatar.dart';
import 'match_detail_screen.dart';
import 'match_form_sheet.dart';
import '../widgets/expressive.dart';

class MatchesScreen extends ConsumerWidget {
  const MatchesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matchesAsync = ref.watch(matchesProvider);
    final canCreate = ref.watch(canCreateMatchdayProvider);
    final now = DateTime.now();

    return Scaffold(
      appBar: AppBar(title: const Text('Jornadas')),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => showMatchFormSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('Nueva jornada'),
            )
          : null,
      body: matchesAsync.when(
        loading: () => const LoadingView(),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'No se pudieron traer las jornadas',
          subtitle: '$e',
        ),
        data: (matches) {
          if (matches.isEmpty) {
            return EmptyState(
              icon: Icons.sports_soccer,
              title: 'Todavía no hay jornadas',
              subtitle: canCreate
                  ? 'Crea la primera con el botón de abajo.'
                  : 'Cuando alguien cree una jornada, sale aquí.',
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
                for (final (i, m) in upcoming.indexed)
                  _UpcomingMatchCard(match: m, highlight: i == 0),
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

/// Próxima jornada. La primera va destacada (color de contenedor, fecha grande
/// y las caras de los que van).
class _UpcomingMatchCard extends ConsumerWidget {
  const _UpcomingMatchCard({required this.match, this.highlight = false});

  final MatchDay match;
  final bool highlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attendance = ref.watch(attendanceForMatchProvider(match.id));
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final mine = attendance[myUid]?.status;
    final closed = ref.watch(matchClosedProvider(match.id));
    final goingIds = [
      for (final a in attendance.values)
        if (a.status == AttendanceStatus.yes) a.uid,
    ];
    final maybe = attendance.values
        .where((a) => a.status == AttendanceStatus.maybe)
        .length;
    final now = DateTime.now();
    final inProgress = match.isInProgress(now);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hero = highlight && !match.isCancelled;
    final fg = hero ? scheme.onPrimaryContainer : scheme.onSurface;
    final fgSoft = hero
        ? scheme.onPrimaryContainer.withValues(alpha: 0.8)
        : scheme.onSurfaceVariant;

    return Pressable(
      child: Card(
        color: hero ? scheme.primaryContainer : null,
        child: InkWell(
          onTap: () => MatchDetailScreen.open(context, match.id),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _DateBlock(
                      date: match.date,
                      background: hero
                          ? scheme.primary
                          : scheme.surfaceContainerHighest,
                      foreground: hero ? scheme.onPrimary : scheme.onSurface,
                      large: hero,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            inProgress
                                ? 'En curso'
                                : _whenLabel(match.date, now),
                            style: (hero ? text.headlineSmall : text.titleLarge)
                                ?.copyWith(
                                  color: fg,
                                  fontWeight: FontWeight.w800,
                                  decoration: match.isCancelled
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              _weekday(match.date),
                              Fmt.time(match.date),
                              if (match.place != null) match.place!,
                            ].join(' · '),
                            style: text.bodyMedium?.copyWith(color: fgSoft),
                          ),
                        ],
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
                        color: hero
                            ? scheme.onPrimaryContainer
                            : scheme.primary,
                        icon: Icons.play_circle_outline,
                      ),
                  ],
                ),
                if (!match.isCancelled) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _Faces(
                        users: [for (final id in goingIds.take(5)) users[id]],
                        ring: hero
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerLow,
                      ),
                      if (goingIds.isNotEmpty) const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          goingIds.isEmpty && maybe == 0
                              ? 'Nadie ha dicho nada todavía'
                              : '${goingIds.length} van${maybe > 0 ? ' · $maybe quizás' : ''}',
                          style: text.labelLarge?.copyWith(color: fg),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<AttendanceStatus>(
                      emptySelectionAllowed: true,
                      showSelectedIcon: false,
                      style: hero
                          ? ButtonStyle(
                              foregroundColor: WidgetStatePropertyAll(fg),
                              side: WidgetStatePropertyAll(
                                BorderSide(color: fg.withValues(alpha: 0.3)),
                              ),
                              backgroundColor: WidgetStateProperty.resolveWith(
                                (st) => st.contains(WidgetState.selected)
                                    ? scheme.surface.withValues(alpha: 0.85)
                                    : Colors.transparent,
                              ),
                            )
                          : null,
                      selected: {if (mine != null) mine},
                      onSelectionChanged: closed
                          ? null
                          : (sel) {
                              if (sel.isEmpty) return;
                              fireAndForget(
                                ref
                                    .read(repoProvider)
                                    .setIntent(match.id, sel.first),
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
      ),
    );
  }
}

/// Día de la semana y número, en un bloque redondeado.
class _DateBlock extends StatelessWidget {
  const _DateBlock({
    required this.date,
    required this.background,
    required this.foreground,
    this.large = false,
  });

  final DateTime date;
  final Color background;
  final Color foreground;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final weekday = DateFormat.E('es').format(date).replaceAll('.', '');
    return Container(
      width: large ? 64 : 56,
      height: large ? 72 : 60,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(large ? 20 : 16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            weekday.toUpperCase(),
            style: text.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          Text(
            '${date.day}',
            style: (large ? text.headlineMedium : text.titleLarge)?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
              height: 1.05,
            ),
          ),
        ],
      ),
    );
  }
}

/// Caras de los que van, montadas una encima de otra.
class _Faces extends StatelessWidget {
  const _Faces({required this.users, required this.ring});

  final List<AppUser?> users;

  /// Color del fondo: cada cara lleva un aro de ese color para separarla.
  final Color ring;

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) return const SizedBox.shrink();
    const size = 34.0;
    const step = 24.0;
    return SizedBox(
      width: size + step * (users.length - 1),
      height: size,
      child: Stack(
        children: [
          for (final (i, u) in users.indexed)
            Positioned(
              left: step * i,
              child: ShapeBadge(
                shape: AppShapes.forId(u?.uid ?? '?'),
                color: ring,
                size: size,
                child: PlayerAvatar(
                  user: u,
                  radius: (size - 6) / 2.2,
                  avoid: ring,
                ),
              ),
            ),
        ],
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
    final mvp = summary.mvps.map((u) => users[u]?.name ?? '?').join(', ');

    return Pressable(
      child: Card(
        child: InkWell(
          onTap: () => MatchDetailScreen.open(context, match.id),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DateBlock(
                  date: match.date,
                  background: match.isCancelled
                      ? scheme.surfaceContainerHighest
                      : scheme.secondaryContainer,
                  foreground: match.isCancelled
                      ? scheme.onSurfaceVariant
                      : scheme.onSecondaryContainer,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        Fmt.short(match.date),
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          decoration: match.isCancelled
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (match.isCancelled)
                        Text(
                          'Cancelada',
                          style: text.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      else ...[
                        Text(
                          '${summary.players.length} jugadores · ${Fmt.goals(summary.totalGoals)}',
                          style: text.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (mvp.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.emoji_events,
                                  size: 16,
                                  color: scheme.mvpGold,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'MVP $mvp',
                                    overflow: TextOverflow.ellipsis,
                                    style: text.labelLarge?.copyWith(
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
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
                                text: 'Pon tus goles',
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
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Cuándo es, sin repetir la fecha (que ya va en el bloque): hoy, mañana,
/// pasado mañana o en N días.
String _whenLabel(DateTime date, DateTime now) {
  final days = DateTime(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
  return switch (days) {
    0 => 'Hoy',
    1 => 'Mañana',
    2 => 'Pasado mañana',
    < 0 => Fmt.short(date),
    _ => 'En $days días',
  };
}

/// "Miércoles", con mayúscula.
String _weekday(DateTime d) {
  final w = DateFormat.EEEE('es').format(d);
  return w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}';
}
