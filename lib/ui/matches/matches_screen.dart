import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/attendance.dart';
import '../../models/match_day.dart';
import '../widgets/common.dart';
import 'match_detail_screen.dart';
import 'match_form_sheet.dart';
import '../widgets/chalk.dart';
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
                  if (i == 0 && !m.isCancelled)
                    _PitchCard(match: m)
                  else
                    _UpcomingMatchCard(match: m),
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

/// La próxima jornada dibujada en la pizarra: cuándo es a rotulador, la
/// cancha con los que van como fichas en formación (y los "quizás" en el otro
/// campo) y los botones para decir si vas.
class _PitchCard extends ConsumerWidget {
  const _PitchCard({required this.match});

  final MatchDay match;

  // Dónde caen las fichas (fracciones de la cancha): los que van en nuestro
  // campo, los "quizás" en el de enfrente.
  static const _going = [
    Offset(.08, .5),
    Offset(.21, .25),
    Offset(.21, .75),
    Offset(.31, .5),
    Offset(.41, .2),
    Offset(.41, .8),
    Offset(.44, .5),
  ];
  static const _maybe = [
    Offset(.6, .3),
    Offset(.6, .7),
    Offset(.71, .5),
    Offset(.82, .27),
    Offset(.82, .73),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attendance = ref.watch(attendanceForMatchProvider(match.id));
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final closed = ref.watch(matchClosedProvider(match.id));
    final mine = attendance[myUid]?.status;
    final going = [
      for (final a in attendance.values)
        if (a.status == AttendanceStatus.yes) a.uid,
    ];
    final maybe = [
      for (final a in attendance.values)
        if (a.status == AttendanceStatus.maybe) a.uid,
    ];
    final now = DateTime.now();
    final text = Theme.of(context).textTheme;

    String initials(String uid) {
      final name = users[uid]?.name ?? '?';
      return name
          .trim()
          .split(RegExp(r'\s+'))
          .where((p) => p.isNotEmpty)
          .take(2)
          .map((p) => p[0].toUpperCase())
          .join();
    }

    return Pressable(
      child: Card(
        child: InkWell(
          onTap: () => MatchDetailScreen.open(context, match.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Transform.rotate(
                  angle: -.035,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    match.isInProgress(now)
                        ? '¡Se está jugando!'
                        : _whenLabel(match.date, now),
                    style: text.displaySmall?.copyWith(
                      color: Chalk.yellow,
                      fontSize: 34,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text.rich(
                  TextSpan(
                    style: AppTheme.mono(size: 13, color: Chalk.white),
                    children: [
                      TextSpan(
                        text:
                            '${_weekdayShort(match.date)} ${match.date.day} · ${Fmt.time(match.date)}',
                      ),
                      if (match.place != null) ...[
                        const TextSpan(text: ' · '),
                        TextSpan(
                          text: match.place,
                          style: const TextStyle(color: Chalk.green),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: 1.5,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final w = box.maxWidth;
                      final h = box.maxHeight;
                      const t = 30.0;
                      Offset at(Offset f) => Offset(f.dx * w, f.dy * h);
                      final shownGoing = going.take(_going.length).toList();
                      final shownMaybe = maybe.take(_maybe.length).toList();
                      return ChalkPitch(
                        children: [
                          if (shownGoing.length >= 2 && shownMaybe.isNotEmpty)
                            Positioned.fill(
                              child: ChalkArrow(
                                from: at(_going[3]) + const Offset(t / 2, 0),
                                to: at(_maybe[0]) - const Offset(t / 2, 4),
                              ),
                            ),
                          for (final (i, uid) in shownGoing.indexed)
                            Positioned(
                              left: at(_going[i]).dx - t / 2,
                              top: at(_going[i]).dy - t / 2,
                              child: ChalkToken(
                                label: initials(uid),
                                color: Chalk.yellow,
                                filled: true,
                                size: t,
                              ),
                            ),
                          for (final (i, uid) in shownMaybe.indexed)
                            Positioned(
                              left: at(_maybe[i]).dx - t / 2,
                              top: at(_maybe[i]).dy - t / 2,
                              child: ChalkToken(
                                label: initials(uid),
                                color: Chalk.green,
                                dashed: true,
                                size: t,
                              ),
                            ),
                          Positioned(
                            right: 10,
                            bottom: 6,
                            child: Transform.rotate(
                              angle: -.06,
                              child: Text.rich(
                                TextSpan(
                                  style: text.titleMedium?.copyWith(
                                    color: Chalk.yellow,
                                  ),
                                  children: [
                                    TextSpan(
                                      text: going.isEmpty && maybe.isEmpty
                                          ? 'Nadie ha dicho nada todavía'
                                          : '${going.length} van'
                                                '${maybe.isEmpty ? '' : ' · ${maybe.length} quizás'} ',
                                    ),
                                    if (going.isNotEmpty || maybe.isNotEmpty)
                                      TextSpan(
                                        text: '→',
                                        style: AppTheme.mono(
                                          size: 16,
                                          color: Chalk.yellow,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AttendanceStatus>(
                    emptySelectionAllowed: true,
                    showSelectedIcon: false,
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
                      ),
                      ButtonSegment(
                        value: AttendanceStatus.maybe,
                        label: Text('Quizás'),
                      ),
                      ButtonSegment(
                        value: AttendanceStatus.no,
                        label: Text('No voy'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Las demás próximas: compactas, con su bloque de fecha.
class _UpcomingMatchCard extends ConsumerWidget {
  const _UpcomingMatchCard({required this.match});

  final MatchDay match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attendance = ref.watch(attendanceForMatchProvider(match.id));
    final myUid = ref.watch(myUidProvider);
    final mine = attendance[myUid]?.status;
    final closed = ref.watch(matchClosedProvider(match.id));
    final going = attendance.values
        .where((a) => a.status == AttendanceStatus.yes)
        .length;
    final maybe = attendance.values
        .where((a) => a.status == AttendanceStatus.maybe)
        .length;
    final now = DateTime.now();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Pressable(
      child: Card(
        child: InkWell(
          onTap: () => MatchDetailScreen.open(context, match.id),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _DateBlock(date: match.date),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _whenLabel(match.date, now),
                            style: text.titleLarge?.copyWith(
                              decoration: match.isCancelled
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          Text(
                            [
                              Fmt.time(match.date),
                              if (match.place != null) match.place!,
                            ].join(' · '),
                            style: AppTheme.mono(
                              size: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (match.isCancelled)
                      _Hint(
                        text: 'Cancelada',
                        color: scheme.onSurfaceVariant,
                        icon: Icons.event_busy,
                      ),
                  ],
                ),
                if (!match.isCancelled) ...[
                  const SizedBox(height: 10),
                  Text(
                    going == 0 && maybe == 0
                        ? 'Nadie ha dicho nada todavía'
                        : '$going van${maybe > 0 ? ' · $maybe quizás' : ''}',
                    style: text.labelLarge?.copyWith(color: Chalk.yellow),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<AttendanceStatus>(
                      emptySelectionAllowed: true,
                      showSelectedIcon: false,
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
                        ),
                        ButtonSegment(
                          value: AttendanceStatus.maybe,
                          label: Text('Quizás'),
                        ),
                        ButtonSegment(
                          value: AttendanceStatus.no,
                          label: Text('No voy'),
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

/// Día de la semana y número, en un recuadro de tiza.
class _DateBlock extends StatelessWidget {
  const _DateBlock({required this.date, this.dim = false});

  final DateTime date;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final color = dim ? Chalk.dim : Chalk.white;
    return Container(
      width: 54,
      height: 58,
      decoration: ShapeDecoration(
        shape: ChalkBorder(
          side: BorderSide(color: Chalk.line(dim ? .35 : .6), width: 1.6),
          radius: 12,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _weekdayShort(date),
            style: AppTheme.mono(size: 10.5, weight: 700, color: Chalk.green),
          ),
          Text(
            '${date.day}',
            style: TextStyle(
              fontFamily: 'Marker',
              fontSize: 24,
              height: 1.05,
              color: color,
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
                _DateBlock(date: match.date, dim: match.isCancelled),
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

/// "MIÉ", para los bloques de fecha.
String _weekdayShort(DateTime d) =>
    DateFormat.E('es').format(d).replaceAll('.', '').toUpperCase();
