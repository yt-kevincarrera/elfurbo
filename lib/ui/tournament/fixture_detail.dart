import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messenger.dart';
import '../../core/formatters.dart';
import '../../data/providers.dart';
import '../../data/tournament_providers.dart';
import '../../models/app_user.dart';
import '../../models/tournament.dart';
import '../widgets/common.dart';
import '../widgets/expressive.dart';
import 'fixtures_screen.dart';
import 'result_entry.dart';
import 'teams_screen.dart';

/// Un partido: marcador, goles, tarjetas, quién jugó y quién está suspendido.
/// El anotador (o el staff) pone el resultado; los organizadores lo programan.
class FixtureDetailScreen extends ConsumerWidget {
  const FixtureDetailScreen({super.key, required this.fixtureId});

  final String fixtureId;

  static Future<void> open(BuildContext context, String fixtureId) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FixtureDetailScreen(fixtureId: fixtureId),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ref.watch(fixtureByIdProvider(fixtureId));
    final t = ref.watch(tournamentProvider);
    if (f == null || t == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.event_busy,
          title: 'Ese partido ya no está',
        ),
      );
    }
    final teams = {for (final x in ref.watch(teamsProvider)) x.id: x};
    final all = ref.watch(fixturesProvider);
    final byId = {for (final x in all) x.id: x};
    final lastRound = lastKnockoutRound(all);
    final events = ref.watch(eventsOfFixtureProvider(f.id));
    final lineup = ref.watch(lineupOfFixtureProvider(f.id));
    final suspended = ref.watch(suspensionsProvider)[f.id] ?? const {};
    final users = ref.watch(usersByIdProvider);
    final myUid = ref.watch(myUidProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final isStaff = ref.watch(isStaffProvider);
    final readOnly = ref.watch(clubReadOnlyProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final canScore =
        !readOnly &&
        t.status == TournamentStatus.inProgress &&
        f.hasTeams &&
        f.status != FixtureStatus.cancelled &&
        (isStaff || f.scorerMemberId == myUid);
    String name(String id) => users[id]?.name ?? 'Jugador';

    Widget teamColumn(bool home) {
      final id = home ? f.homeTeamId : f.awayTeamId;
      final team = teams[id];
      return Expanded(
        child: InkWell(
          onTap: team == null
              ? null
              : () => TeamDetailScreen.open(context, team.id),
          child: Column(
            children: [
              if (team != null) TeamBadge(team: team, size: 56),
              const SizedBox(height: 6),
              Text(
                sideLabel(f, home, teams, byId, lastRound),
                textAlign: TextAlign.center,
                style: text.titleSmall,
              ),
            ],
          ),
        ),
      );
    }

    final scoreText = switch (f.status) {
      FixtureStatus.played => '${f.homeScore} - ${f.awayScore}',
      FixtureStatus.walkover => 'W.O.',
      FixtureStatus.cancelled => 'Cancelado',
      FixtureStatus.scheduled => 'vs',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(roundLabel(f, lastRound)),
        actions: [
          if (isAdmin && !readOnly && t.status != TournamentStatus.finished)
            _AdminMenu(fixture: f),
        ],
      ),
      floatingActionButton: canScore
          ? FloatingActionButton.extended(
              onPressed: () => ResultEntryScreen.open(context, f.id),
              icon: const Icon(Icons.scoreboard_outlined),
              label: Text(f.decided ? 'Corregir resultado' : 'Poner resultado'),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                teamColumn(true),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    children: [
                      Text(
                        scoreText,
                        style: text.headlineMedium?.copyWith(
                          fontFamily: 'Mono',
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (f.homePens != null)
                        Text(
                          '(${f.homePens}-${f.awayPens} pen.)',
                          style: text.bodySmall,
                        ),
                    ],
                  ),
                ),
                teamColumn(false),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              [
                if (f.groupLabel != null) 'Grupo ${f.groupLabel}',
                if (f.startsAt != null) Fmt.full(f.startsAt!),
                ?f.place,
                if (f.scorerMemberId != null)
                  'Anota ${name(f.scorerMemberId!)}',
              ].join(' · '),
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (events.isNotEmpty) ...[
            const SectionTitle('Lo que pasó'),
            GroupedSection(
              children: [
                for (final e in events)
                  ListTile(
                    dense: true,
                    leading: Text(switch (e.kind) {
                      EventKind.goal => '⚽',
                      EventKind.ownGoal => '🙈',
                      EventKind.yellow => '🟨',
                      EventKind.red => '🟥',
                      EventKind.mvp => '⭐',
                    }, style: const TextStyle(fontSize: 22)),
                    title: Text(
                      '${name(e.memberId)}${e.kind == EventKind.ownGoal ? ' (en propia)' : ''}',
                    ),
                    subtitle: Text(
                      [
                        teams[e.teamId]?.shortName ?? '',
                        if (e.assistMemberId != null)
                          'asistencia de ${name(e.assistMemberId!)}',
                        if (e.minute != null) "${e.minute}'",
                        if (e.kind == EventKind.mvp) 'MVP del partido',
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
          ],
          if (lineup.isNotEmpty) ...[
            const SectionTitle('Jugaron'),
            for (final home in [true, false])
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '${teams[home ? f.homeTeamId : f.awayTeamId]?.shortName ?? ''}: '
                  '${lineup.where((l) => l.teamId == (home ? f.homeTeamId : f.awayTeamId)).map((l) => name(l.memberId)).join(', ')}',
                  style: text.bodyMedium,
                ),
              ),
          ],
          if (suspended.isNotEmpty) ...[
            const SectionTitle('Suspendidos'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                suspended.map(name).join(', '),
                style: text.bodyMedium?.copyWith(color: scheme.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AdminMenu extends ConsumerWidget {
  const _AdminMenu({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = fixture;
    final repo = ref.read(repoProvider);
    final teams = {for (final t in ref.watch(teamsProvider)) t.id: t};
    return PopupMenuButton<String>(
      onSelected: (v) async {
        switch (v) {
          case 'schedule':
            await showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => _ScheduleSheet(fixture: f),
            );
          case 'walkover':
            final winner = await showDialog<String>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: const Text('¿Quién gana sin jugar?'),
                children: [
                  for (final id in [f.homeTeamId, f.awayTeamId])
                    if (id != null)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, id),
                        child: Text(teams[id]?.name ?? ''),
                      ),
                ],
              ),
            );
            if (winner == null) return;
            fireAndForget(
              repo.setFixtureStatus(f.id, 'walkover', walkoverWinner: winner),
              success: 'Listo, ganado sin jugar',
            );
          case 'cancel':
            fireAndForget(
              repo.setFixtureStatus(f.id, 'cancelled'),
              success: 'Listo, partido cancelado',
            );
          case 'reset':
            fireAndForget(
              repo.setFixtureStatus(f.id, 'scheduled'),
              success: 'Listo, otra vez por jugar',
            );
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'schedule',
          child: Text('Fecha, terreno y anotador'),
        ),
        if (f.hasTeams && !f.decided)
          const PopupMenuItem(
            value: 'walkover',
            child: Text('Ganado sin jugar'),
          ),
        if (f.status != FixtureStatus.cancelled && !f.decided)
          const PopupMenuItem(value: 'cancel', child: Text('Cancelar')),
        if (f.status != FixtureStatus.scheduled)
          const PopupMenuItem(
            value: 'reset',
            child: Text('Borrar el resultado'),
          ),
      ],
    );
  }
}

class _ScheduleSheet extends ConsumerStatefulWidget {
  const _ScheduleSheet({required this.fixture});

  final Fixture fixture;

  @override
  ConsumerState<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends ConsumerState<_ScheduleSheet> {
  late DateTime? _when = widget.fixture.startsAt;
  late final _place = TextEditingController(text: widget.fixture.place ?? '');
  late String? _scorer = widget.fixture.scorerMemberId;

  @override
  void dispose() {
    _place.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: _when ?? now,
      firstDate: now.subtract(const Duration(days: 60)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when ?? DateTime(2026, 1, 1, 15)),
    );
    if (time == null) return;
    setState(
      () => _when = DateTime(
        day.year,
        day.month,
        day.day,
        time.hour,
        time.minute,
      ),
    );
  }

  void _save() {
    final f = widget.fixture;
    Navigator.pop(context);
    fireAndForget(
      ref
          .read(repoProvider)
          .scheduleFixture(
            f.id,
            startsAt: _when != f.startsAt ? _when : null,
            place: _place.text.trim() != (f.place ?? '') ? _place.text : null,
            scorerMemberId: _scorer != f.scorerMemberId ? _scorer : null,
            clearScorer: _scorer == null && f.scorerMemberId != null,
          ),
      success: 'Listo, partido programado',
    );
  }

  @override
  Widget build(BuildContext context) {
    final members = ref
        .watch(activeUsersProvider)
        .where((u) => u.role != UserRole.guest)
        .toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Programar el partido',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Cuándo'),
            subtitle: Text(_when == null ? 'Sin fecha' : Fmt.full(_when!)),
            trailing: const Icon(Icons.event),
            onTap: _pick,
          ),
          TextField(
            controller: _place,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Terreno'),
          ),
          DropdownButtonFormField<String?>(
            initialValue: members.any((m) => m.uid == _scorer) ? _scorer : null,
            decoration: const InputDecoration(labelText: 'Anotador'),
            items: [
              const DropdownMenuItem(value: null, child: Text('El staff')),
              for (final m in members)
                DropdownMenuItem(value: m.uid, child: Text(m.name)),
            ],
            onChanged: (v) => setState(() => _scorer = v),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Guardar')),
        ],
      ),
    );
  }
}
