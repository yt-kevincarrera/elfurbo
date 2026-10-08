import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../data/tournament_providers.dart';
import '../../domain/tournament/generators.dart';
import '../../domain/tournament/knockout.dart';
import '../../domain/tournament/player_stats.dart';
import '../../domain/tournament/standings.dart';
import '../../models/tournament.dart';
import '../widgets/chalk.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import 'fixture_detail.dart';
import 'teams_screen.dart';

/// Nombre de la ronda de un partido ("Jornada 3", "Semifinales", "Tercer puesto").
String roundLabel(Fixture f, int lastKnockoutRound) => switch (f.stage) {
  FixtureStage.third => 'Tercer puesto',
  FixtureStage.knockout => knockoutRoundName(lastKnockoutRound - f.round),
  _ => 'Jornada ${f.round}',
};

/// La última ronda de eliminatoria (la de la final), o 0 si no hay.
int lastKnockoutRound(Iterable<Fixture> fixtures) => fixtures
    .where((f) => f.stage == FixtureStage.knockout)
    .fold(0, (m, f) => f.round > m ? f.round : m);

/// Quién juega en un lado: el equipo, o de dónde sale ("1.º del grupo A",
/// "Ganador de Semifinales").
String sideLabel(
  Fixture f,
  bool home,
  Map<String, Team> teams,
  Map<String, Fixture> fixtures,
  int lastRound,
) {
  final teamId = home ? f.homeTeamId : f.awayTeamId;
  if (teamId != null) return teams[teamId]?.name ?? 'Equipo';
  final s = home ? f.homeSource : f.awaySource;
  if (s == null) return 'Por definir';
  if (s.group != null) return '${s.pos}.º del grupo ${s.group}';
  final ref = fixtures[s.winnerOf ?? s.loserOf];
  final name = ref == null ? 'el partido anterior' : roundLabel(ref, lastRound);
  final slot = ref?.slot == null ? '' : ' ${(ref!.slot ?? 0) + 1}';
  return s.winnerOf != null
      ? 'Ganador de $name$slot'
      : 'Perdedor de $name$slot';
}

/// Partidos del torneo: calendario, tabla (o cuadro) y goleadores.
class FixturesScreen extends ConsumerWidget {
  const FixturesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fixtures = ref.watch(fixturesProvider);
    final t = ref.watch(tournamentProvider);
    if (t == null) {
      return const Scaffold(body: LoadingView(message: 'Un momentico…'));
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Partidos'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Calendario'),
              Tab(text: 'Tabla'),
              Tab(text: 'Goleadores'),
            ],
          ),
        ),
        body: fixtures.isEmpty
            ? EmptyState(
                icon: Icons.calendar_month_outlined,
                title: 'Todavía no hay calendario',
                subtitle: switch (t.status) {
                  TournamentStatus.draft || TournamentStatus.registration =>
                    'Sale cuando cierre la inscripción.',
                  _ => 'El organizador lo genera desde Admin.',
                },
              )
            : const TabBarView(children: [_Calendar(), _Tables(), _Leaders()]),
      ),
    );
  }
}

class _Calendar extends ConsumerWidget {
  const _Calendar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fixtures = ref.watch(fixturesProvider);
    final lastRound = lastKnockoutRound(fixtures);
    final sections = <String, List<Fixture>>{};
    for (final f in fixtures) {
      sections.putIfAbsent(roundLabel(f, lastRound), () => []).add(f);
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        for (final s in sections.entries) ...[
          SectionTitle(s.key),
          GroupedSection(
            children: [for (final f in s.value) FixtureTile(fixture: f)],
          ),
        ],
      ],
    );
  }
}

/// Un partido en una lista: los dos equipos con el marcador, cuándo y dónde.
class FixtureTile extends ConsumerWidget {
  const FixtureTile({super.key, required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = fixture;
    final teams = {for (final t in ref.watch(teamsProvider)) t.id: t};
    final all = ref.watch(fixturesProvider);
    final byId = {for (final x in all) x.id: x};
    final lastRound = lastKnockoutRound(all);
    final myUid = ref.watch(myUidProvider);
    final myTeam = ref.watch(myTeamProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final winner = f.isKnockout ? winnerOf(f) : null;

    Widget side(bool home) {
      final id = home ? f.homeTeamId : f.awayTeamId;
      final team = teams[id];
      final label = sideLabel(f, home, teams, byId, lastRound);
      final bold = winner != null && winner == id;
      return Expanded(
        child: Row(
          mainAxisAlignment: home
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            if (!home && team != null) ...[
              TeamBadge(team: team, size: 28),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                textAlign: home ? TextAlign.end : TextAlign.start,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(
                  fontWeight: bold || id == myTeam?.id ? FontWeight.bold : null,
                  color: team == null ? scheme.onSurfaceVariant : null,
                ),
              ),
            ),
            if (home && team != null) ...[
              const SizedBox(width: 6),
              TeamBadge(team: team, size: 28),
            ],
          ],
        ),
      );
    }

    final score = switch (f.status) {
      FixtureStatus.played =>
        '${f.homeScore} - ${f.awayScore}'
            '${f.homePens != null ? '\n(${f.homePens}-${f.awayPens} pen.)' : ''}',
      FixtureStatus.walkover => 'W.O.',
      FixtureStatus.cancelled => 'Cancel.',
      FixtureStatus.scheduled =>
        f.startsAt == null ? 'vs' : Fmt.time(f.startsAt!),
    };
    final toScore = f.scorerMemberId == myUid && !f.decided && f.hasTeams;
    return InkWell(
      onTap: () => FixtureDetailScreen.open(context, f.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          children: [
            Row(
              children: [
                side(true),
                SizedBox(
                  width: 72,
                  child: Text(
                    score,
                    textAlign: TextAlign.center,
                    style: text.titleMedium?.copyWith(
                      fontFamily: 'Mono',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                side(false),
              ],
            ),
            if (f.startsAt != null ||
                f.place != null ||
                f.groupLabel != null ||
                toScore)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [
                    if (f.groupLabel != null) 'Grupo ${f.groupLabel}',
                    if (f.startsAt != null) Fmt.short(f.startsAt!),
                    ?f.place,
                    if (toScore) 'Te toca anotarlo',
                  ].join(' · '),
                  style: text.bodySmall?.copyWith(
                    color: toScore ? Chalk.yellow : scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Tables extends ConsumerWidget {
  const _Tables();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tournamentProvider)!;
    final groups = ref.watch(groupLabelsProvider);
    final knockout = ref
        .watch(fixturesProvider)
        .where((f) => f.isKnockout)
        .toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (t.format == TournamentFormat.league)
          const StandingsTable(group: null),
        for (final g in groups) ...[
          SectionTitle('Grupo $g'),
          StandingsTable(group: g),
        ],
        if (knockout.isNotEmpty) ...[
          const SectionTitle('Cuadro'),
          BracketView(fixtures: knockout),
        ],
      ],
    );
  }
}

/// La tabla de la liga o de un grupo.
class StandingsTable extends ConsumerWidget {
  const StandingsTable({super.key, required this.group});

  final String? group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(standingsProvider(group));
    final teams = {for (final t in ref.watch(teamsProvider)) t.id: t};
    final myTeam = ref.watch(myTeamProvider);
    final advance = group == null
        ? 0
        : ref.watch(tournamentProvider)?.rules.advancePerGroup ?? 0;
    final text = Theme.of(context).textTheme;
    TableRow row(List<String> cells, {bool header = false, StandingRow? r}) =>
        TableRow(
          children: [
            for (final (i, c) in cells.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Text(
                  c,
                  textAlign: i == 1 ? TextAlign.start : TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: (header ? text.labelMedium : text.bodyMedium)
                      ?.copyWith(
                        fontWeight: r != null && r.teamId == myTeam?.id
                            ? FontWeight.bold
                            : null,
                      ),
                ),
              ),
          ],
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Table(
        columnWidths: const {
          0: FixedColumnWidth(28),
          1: FlexColumnWidth(),
          2: FixedColumnWidth(30),
          3: FixedColumnWidth(30),
          4: FixedColumnWidth(30),
          5: FixedColumnWidth(30),
          6: FixedColumnWidth(36),
          7: FixedColumnWidth(36),
        },
        children: [
          row(['', 'Equipo', 'PJ', 'G', 'E', 'P', 'DG', 'Pts'], header: true),
          for (final (i, r) in rows.indexed)
            row([
              '${i + 1}${i < advance ? '•' : ''}',
              teams[r.teamId]?.name ?? '',
              '${r.played}',
              '${r.won}',
              '${r.drawn}',
              '${r.lost}',
              '${r.goalDiff > 0 ? '+' : ''}${r.goalDiff}',
              '${r.points}',
            ], r: r),
        ],
      ),
    );
  }
}

/// El cuadro de eliminatoria: una columna por ronda, con líneas de tiza.
class BracketView extends ConsumerWidget {
  const BracketView({super.key, required this.fixtures});

  final List<Fixture> fixtures;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teams = {for (final t in ref.watch(teamsProvider)) t.id: t};
    final all = ref.watch(fixturesProvider);
    final byId = {for (final x in all) x.id: x};
    final lastRound = lastKnockoutRound(all);
    final main = fixtures.where((f) => f.stage == FixtureStage.knockout);
    final rounds = <int, List<Fixture>>{};
    for (final f in main) {
      rounds.putIfAbsent(f.round, () => []).add(f);
    }
    final keys = rounds.keys.toList()..sort();
    final third = fixtures.where((f) => f.stage == FixtureStage.third);
    const cardHeight = 64.0;
    const gap = 12.0;
    final firstCount = keys.isEmpty ? 0 : rounds[keys.first]!.length;
    final height = firstCount * (cardHeight + gap);
    final text = Theme.of(context).textTheme;

    Widget card(Fixture f) {
      final w = winnerOf(f);
      Widget line(bool home) {
        final id = home ? f.homeTeamId : f.awayTeamId;
        final score = home ? f.homeScore : f.awayScore;
        final pens = home ? f.homePens : f.awayPens;
        return Row(
          children: [
            Expanded(
              child: Text(
                sideLabel(f, home, teams, byId, lastRound),
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                  fontWeight: w != null && w == id ? FontWeight.bold : null,
                ),
              ),
            ),
            Text(
              f.status == FixtureStatus.played
                  ? '$score${pens == null ? '' : ' ($pens)'}'
                  : '',
              style: text.bodySmall?.copyWith(fontFamily: 'Mono'),
            ),
          ],
        );
      }

      return InkWell(
        onTap: () => FixtureDetailScreen.open(context, f.id),
        child: Container(
          height: cardHeight,
          width: 160,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: ShapeDecoration(
            shape: ChalkBorder(
              radius: 10,
              side: BorderSide(color: Chalk.line(.6), width: 1.4),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [line(true), line(false)],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            height: height + 32,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in keys) ...[
                  Column(
                    children: [
                      SizedBox(
                        height: 24,
                        child: Text(
                          knockoutRoundName(lastRound - r),
                          style: text.labelMedium,
                        ),
                      ),
                      SizedBox(
                        height: height,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [for (final f in rounds[r]!) card(f)],
                        ),
                      ),
                    ],
                  ),
                  if (r != keys.last)
                    CustomPaint(
                      size: Size(24, height + 24),
                      painter: _Connectors(
                        from: rounds[r]!.length,
                        top: 24,
                        height: height,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        for (final f in third)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Text('Tercer puesto  ', style: text.labelMedium),
                card(f),
              ],
            ),
          ),
      ],
    );
  }
}

/// Las líneas que juntan cada par de partidos de una ronda con el de la siguiente.
class _Connectors extends CustomPainter {
  _Connectors({required this.from, required this.top, required this.height});

  final int from;
  final double top;
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    if (from < 2) return;
    final paint = Paint()
      ..color = Chalk.line(.5)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final step = height / from;
    for (var i = 0; i + 1 < from; i += 2) {
      final y1 = top + step * (i + .5);
      final y2 = top + step * (i + 1.5);
      final mid = (y1 + y2) / 2;
      final x = size.width / 2;
      canvas.drawPath(
        Path()
          ..moveTo(0, y1)
          ..lineTo(x, y1)
          ..lineTo(x, y2)
          ..lineTo(0, y2)
          ..moveTo(x, mid)
          ..lineTo(size.width, mid),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Connectors old) =>
      old.from != from || old.height != height;
}

class _Leaders extends ConsumerWidget {
  const _Leaders();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(tournamentPlayerStatsProvider);
    final users = ref.watch(usersByIdProvider);
    final rosters = ref.watch(rostersProvider);
    final teams = {for (final t in ref.watch(teamsProvider)) t.id: t};
    String teamOf(String member) {
      for (final e in rosters.entries) {
        if (e.value.any((p) => p.memberId == member)) {
          return teams[e.key]?.shortName ?? '';
        }
      }
      return '';
    }

    Widget list(
      String title,
      int Function(TournamentPlayerStats) value,
      String unit,
    ) {
      final top = leaders(stats, value).take(10).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(title),
          if (top.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('Todavía nadie.'),
            )
          else
            GroupedSection(
              children: [
                for (final (i, s) in top.indexed)
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
                    title: Text(users[s.memberId]?.name ?? 'Jugador'),
                    subtitle: Text(teamOf(s.memberId)),
                    trailing: Text(
                      '${value(s)} $unit',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
              ],
            ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        list('Goleadores', (s) => s.goals, 'G'),
        list('Asistencias', (s) => s.assists, 'A'),
        list('MVP de partido', (s) => s.mvps, 'MVP'),
        list('Tarjetas', (s) => s.yellows + s.reds * 3, 'pts'),
      ],
    );
  }
}
