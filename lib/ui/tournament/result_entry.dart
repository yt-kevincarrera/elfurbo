import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/sync/command.dart';
import '../../core/app_messenger.dart';
import '../../data/providers.dart';
import '../../data/tournament_providers.dart';
import '../../models/tournament.dart';
import '../widgets/common.dart';

/// Poner (o corregir) el resultado de un partido: marcador, penales si es
/// eliminatoria y empatan, quién jugó, goles con su asistencia, tarjetas y el
/// MVP. Va por la cola: se puede anotar en el terreno sin señal.
class ResultEntryScreen extends ConsumerStatefulWidget {
  const ResultEntryScreen({super.key, required this.fixtureId});

  final String fixtureId;

  static Future<void> open(BuildContext context, String fixtureId) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ResultEntryScreen(fixtureId: fixtureId),
        ),
      );

  @override
  ConsumerState<ResultEntryScreen> createState() => _ResultEntryState();
}

class _ResultEntryState extends ConsumerState<ResultEntryScreen> {
  int _home = 0;
  int _away = 0;
  int _homePens = 0;
  int _awayPens = 0;
  final _lineupHome = <String>{};
  final _lineupAway = <String>{};
  final _events = <FixtureEvent>[];
  String? _mvp;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final f = ref.read(fixtureByIdProvider(widget.fixtureId));
    if (f != null && f.hasTeams) _load(f);
  }

  /// Lo que ya había (al corregir) o la plantilla sin los suspendidos.
  void _load(Fixture f) {
    if (_loaded) return;
    _loaded = true;
    _home = f.homeScore ?? 0;
    _away = f.awayScore ?? 0;
    _homePens = f.homePens ?? 0;
    _awayPens = f.awayPens ?? 0;
    final lineup = ref.read(lineupOfFixtureProvider(f.id));
    final suspended = ref.read(suspensionsProvider)[f.id] ?? const <String>{};
    for (final (side, team) in [
      (_lineupHome, f.homeTeamId),
      (_lineupAway, f.awayTeamId),
    ]) {
      final saved = lineup
          .where((l) => l.teamId == team)
          .map((l) => l.memberId);
      side.addAll(
        saved.isNotEmpty
            ? saved
            : ref
                  .read(rosterProvider(team!))
                  .map((p) => p.memberId)
                  .where((m) => !suspended.contains(m)),
      );
    }
    for (final e in ref.read(eventsOfFixtureProvider(f.id))) {
      if (e.kind == EventKind.mvp) {
        _mvp = e.memberId;
      } else {
        _events.add(e);
      }
    }
  }

  (int, int) _goals(Fixture f) {
    var h = 0;
    var a = 0;
    for (final e in _events) {
      if (e.kind == EventKind.goal) {
        e.teamId == f.homeTeamId ? h++ : a++;
      } else if (e.kind == EventKind.ownGoal) {
        e.teamId == f.homeTeamId ? a++ : h++;
      }
    }
    return (h, a);
  }

  Future<void> _addGoal(Fixture f, bool home) async {
    final team = home ? f.homeTeamId! : f.awayTeamId!;
    final other = home ? f.awayTeamId! : f.homeTeamId!;
    final users = ref.read(usersByIdProvider);
    final mine = (home ? _lineupHome : _lineupAway).toList();
    final theirs = (home ? _lineupAway : _lineupHome).toList();
    final picked = await showDialog<(String, bool)>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('¿Quién lo metió?'),
        children: [
          for (final m in mine)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, (m, false)),
              child: Text(users[m]?.name ?? 'Jugador'),
            ),
          if (theirs.isNotEmpty) const Divider(),
          for (final m in theirs)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, (m, true)),
              child: Text('${users[m]?.name ?? 'Jugador'} (en propia)'),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final (scorer, own) = picked;
    String? assist;
    if (!own) {
      assist = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('¿Asistencia?'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Sin asistencia'),
            ),
            for (final m in mine.where((m) => m != scorer))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, m),
                child: Text(users[m]?.name ?? 'Jugador'),
              ),
          ],
        ),
      );
      if (assist == null) return;
    }
    setState(() {
      _events.add(
        FixtureEvent(
          id: uuidV4(),
          fixtureId: f.id,
          teamId: own ? other : team,
          memberId: scorer,
          kind: own ? EventKind.ownGoal : EventKind.goal,
          assistMemberId: assist == null || assist.isEmpty ? null : assist,
        ),
      );
      // El marcador sigue a los goles.
      final (h, a) = _goals(f);
      _home = h;
      _away = a;
    });
  }

  Future<void> _addCard(Fixture f, EventKind kind) async {
    final users = ref.read(usersByIdProvider);
    final picked = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(kind == EventKind.red ? 'Roja para…' : 'Amarilla para…'),
        children: [
          for (final (team, members) in [
            (f.homeTeamId!, _lineupHome),
            (f.awayTeamId!, _lineupAway),
          ])
            for (final m in members)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, (team, m)),
                child: Text(users[m]?.name ?? 'Jugador'),
              ),
        ],
      ),
    );
    if (picked == null) return;
    setState(
      () => _events.add(
        FixtureEvent(
          id: uuidV4(),
          fixtureId: f.id,
          teamId: picked.$1,
          memberId: picked.$2,
          kind: kind,
        ),
      ),
    );
  }

  void _save(Fixture f) {
    final anyGoal = _events.any(
      (e) => e.kind == EventKind.goal || e.kind == EventKind.ownGoal,
    );
    final (h, a) = _goals(f);
    if (anyGoal && (h != _home || a != _away)) {
      showMessage('Los goles ($h-$a) no suman el marcador ($_home-$_away).');
      return;
    }
    final tie = _home == _away;
    if (f.isKnockout && tie && _homePens == _awayPens) {
      showMessage('En eliminatoria un empate se decide por penales.');
      return;
    }
    final events = [
      for (final e in _events) e.toJson(),
      if (_mvp != null)
        FixtureEvent(
          id: uuidV4(),
          fixtureId: f.id,
          teamId: _lineupHome.contains(_mvp) ? f.homeTeamId! : f.awayTeamId!,
          memberId: _mvp!,
          kind: EventKind.mvp,
        ).toJson(),
    ];
    final usePens = f.isKnockout && tie;
    Navigator.pop(context);
    fireAndForget(
      ref
          .read(repoProvider)
          .fixtureResult(
            fixtureId: f.id,
            homeScore: _home,
            awayScore: _away,
            homePens: usePens ? _homePens : null,
            awayPens: usePens ? _awayPens : null,
            events: events,
            lineupHome: _lineupHome.toList(),
            lineupAway: _lineupAway.toList(),
          ),
      success: '¡Resultado guardado!',
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(fixtureByIdProvider(widget.fixtureId));
    if (f == null || !f.hasTeams) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.event_busy,
          title: 'Todavía no se sabe quién juega',
        ),
      );
    }
    final teams = {for (final t in ref.watch(teamsProvider)) t.id: t};
    final users = ref.watch(usersByIdProvider);
    final suspended = ref.watch(suspensionsProvider)[f.id] ?? const <String>{};
    final home = teams[f.homeTeamId]!;
    final away = teams[f.awayTeamId]!;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    String name(String id) => users[id]?.name ?? 'Jugador';

    Widget lineupSection(Team team, Set<String> chosen) {
      final roster = ref.watch(rosterProvider(team.id));
      return ExpansionTile(
        title: Text('Jugaron por ${team.name} (${chosen.length})'),
        children: [
          for (final p in roster)
            CheckboxListTile(
              dense: true,
              value: chosen.contains(p.memberId),
              title: Text(name(p.memberId)),
              subtitle: suspended.contains(p.memberId)
                  ? Text('Suspendido', style: TextStyle(color: scheme.error))
                  : null,
              onChanged: (v) => setState(
                () => v == true
                    ? chosen.add(p.memberId)
                    : chosen.remove(p.memberId),
              ),
            ),
        ],
      );
    }

    final lineup = [..._lineupHome, ..._lineupAway];
    return Scaffold(
      appBar: AppBar(
        title: Text('${home.shortName} - ${away.shortName}'),
        actions: [
          TextButton(onPressed: () => _save(f), child: const Text('Guardar')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SectionTitle('Marcador'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                CounterField(
                  label: home.name,
                  value: _home,
                  max: 99,
                  onChanged: (v) => setState(() => _home = v),
                ),
                const SizedBox(height: 8),
                CounterField(
                  label: away.name,
                  value: _away,
                  max: 99,
                  onChanged: (v) => setState(() => _away = v),
                ),
                if (f.isKnockout && _home == _away) ...[
                  const SizedBox(height: 12),
                  Text('Penales', style: text.titleSmall),
                  const SizedBox(height: 4),
                  CounterField(
                    label: home.shortName,
                    value: _homePens,
                    max: 99,
                    onChanged: (v) => setState(() => _homePens = v),
                  ),
                  const SizedBox(height: 8),
                  CounterField(
                    label: away.shortName,
                    value: _awayPens,
                    max: 99,
                    onChanged: (v) => setState(() => _awayPens = v),
                  ),
                ],
              ],
            ),
          ),
          const SectionTitle('Quién jugó'),
          lineupSection(home, _lineupHome),
          lineupSection(away, _lineupAway),
          SectionTitle(
            'Goles y tarjetas',
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.add),
              onSelected: (v) => switch (v) {
                'home' => _addGoal(f, true),
                'away' => _addGoal(f, false),
                'yellow' => _addCard(f, EventKind.yellow),
                _ => _addCard(f, EventKind.red),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'home',
                  child: Text('Gol de ${home.name}'),
                ),
                PopupMenuItem(
                  value: 'away',
                  child: Text('Gol de ${away.name}'),
                ),
                const PopupMenuItem(value: 'yellow', child: Text('Amarilla')),
                const PopupMenuItem(value: 'red', child: Text('Roja')),
              ],
            ),
          ),
          if (_events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Opcional: con los goles salen los goleadores y las asistencias.',
                style: text.bodySmall,
              ),
            ),
          for (final e in _events)
            ListTile(
              dense: true,
              leading: Text(switch (e.kind) {
                EventKind.goal => '⚽',
                EventKind.ownGoal => '🙈',
                EventKind.yellow => '🟨',
                _ => '🟥',
              }, style: const TextStyle(fontSize: 20)),
              title: Text(
                '${name(e.memberId)}${e.kind == EventKind.ownGoal ? ' (en propia)' : ''}',
              ),
              subtitle: e.assistMemberId == null
                  ? null
                  : Text('Asistencia de ${name(e.assistMemberId!)}'),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _events.remove(e);
                  if (e.kind == EventKind.goal || e.kind == EventKind.ownGoal) {
                    final (h, a) = _goals(f);
                    _home = h;
                    _away = a;
                  }
                }),
              ),
            ),
          const SectionTitle('MVP del partido'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: DropdownButtonFormField<String?>(
              initialValue: lineup.contains(_mvp) ? _mvp : null,
              items: [
                const DropdownMenuItem(value: null, child: Text('Sin MVP')),
                for (final m in lineup)
                  DropdownMenuItem(value: m, child: Text(name(m))),
              ],
              onChanged: (v) => setState(() => _mvp = v),
            ),
          ),
        ],
      ),
    );
  }
}
