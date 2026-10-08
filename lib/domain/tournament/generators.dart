import '../../models/tournament.dart';

/// Un partido por crear (va en `fixtures.generate`).
class FixtureDraft {
  FixtureDraft({
    required this.id,
    required this.stage,
    required this.round,
    this.groupLabel,
    this.leg = 1,
    this.slot,
    this.homeTeamId,
    this.awayTeamId,
    this.homeSource,
    this.awaySource,
    this.startsAt,
  });

  final String id;
  final FixtureStage stage;
  final int round;
  final String? groupLabel;
  final int leg;
  final int? slot;
  final String? homeTeamId;
  final String? awayTeamId;
  final TeamSource? homeSource;
  final TeamSource? awaySource;
  DateTime? startsAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'stage': stage.name,
    'round': round,
    'groupLabel': ?groupLabel,
    'leg': leg,
    'slot': ?slot,
    'homeTeamId': ?homeTeamId,
    'awayTeamId': ?awayTeamId,
    if (homeSource != null) 'homeSource': homeSource!.toJson(),
    if (awaySource != null) 'awaySource': awaySource!.toJson(),
    if (startsAt != null) 'startsAt': startsAt!.toUtc().toIso8601String(),
  };
}

/// Quien entra en un cuadro: un equipo ya conocido o el que salga de algún
/// lado (un puesto de grupo).
class Entrant {
  const Entrant.team(String this.teamId) : source = null;
  const Entrant.source(TeamSource this.source) : teamId = null;

  final String? teamId;
  final TeamSource? source;
}

/// Todos contra todos con el método del círculo: una lista de rondas, cada una
/// con sus partidos `(local, visitante)`. Con un número impar, cada ronda
/// descansa uno. El local se alterna.
List<List<(String, String)>> roundRobinRounds(List<String> teams) {
  final list = <String?>[...teams];
  if (list.length.isOdd) list.add(null);
  final n = list.length;
  final rounds = <List<(String, String)>>[];
  for (var r = 0; r < n - 1; r++) {
    final pairs = <(String, String)>[];
    for (var i = 0; i < n ~/ 2; i++) {
      final a = list[i];
      final b = list[n - 1 - i];
      if (a == null || b == null) continue;
      // El fijo alterna local y visitante; los demás, según su posición.
      final swap = i == 0 ? r.isOdd : i.isOdd;
      pairs.add(swap ? (b, a) : (a, b));
    }
    rounds.add(pairs);
    // Rota todos menos el primero.
    list.insert(1, list.removeLast());
  }
  return rounds;
}

/// Liga a una o dos vueltas (la segunda, con local y visitante cambiados).
List<FixtureDraft> leagueFixtures(
  List<String> teams, {
  required String Function() newId,
  int legs = 1,
  FixtureStage stage = FixtureStage.league,
  String? groupLabel,
  int firstRound = 1,
}) {
  final rounds = roundRobinRounds(teams);
  final out = <FixtureDraft>[];
  for (var leg = 1; leg <= legs; leg++) {
    for (final (r, pairs) in rounds.indexed) {
      for (final (home, away) in pairs) {
        out.add(
          FixtureDraft(
            id: newId(),
            stage: stage,
            round: firstRound + (leg - 1) * rounds.length + r,
            groupLabel: groupLabel,
            leg: leg,
            homeTeamId: leg == 1 ? home : away,
            awayTeamId: leg == 1 ? away : home,
          ),
        );
      }
    }
  }
  return out;
}

/// El orden de siembra de un cuadro de [size] (potencia de 2): el 1 contra el
/// último, y los mejores no se cruzan hasta el final.
List<int> seedOrder(int size) {
  var order = [1];
  while (order.length < size) {
    final n = order.length * 2;
    order = [
      for (final s in order) ...[s, n + 1 - s],
    ];
  }
  return order;
}

int _nextPow2(int n) {
  var p = 1;
  while (p < n) {
    p *= 2;
  }
  return p;
}

/// Eliminación directa con cabezas de serie (en el orden de [entrants]). Si no
/// son potencia de 2, los mejores pasan la primera ronda sin jugar. Con
/// [thirdPlace], el partido por el tercer puesto entre los que pierden las
/// semifinales.
List<FixtureDraft> cupFixtures(
  List<Entrant> entrants, {
  required String Function() newId,
  bool thirdPlace = false,
  int firstRound = 1,
}) {
  if (entrants.length < 2) return const [];
  final size = _nextPow2(entrants.length);
  final order = seedOrder(size);
  // Lo que sale de cada hueco de la ronda anterior: un equipo, una fuente o
  // el ganador de un partido.
  var slots = <Entrant?>[
    for (final s in order) s <= entrants.length ? entrants[s - 1] : null,
  ];
  final out = <FixtureDraft>[];
  var round = firstRound;
  List<FixtureDraft> semis = const [];
  while (slots.length > 1) {
    final next = <Entrant?>[];
    final thisRound = <FixtureDraft>[];
    for (var i = 0; i < slots.length; i += 2) {
      final home = slots[i];
      final away = slots[i + 1];
      if (home == null || away == null) {
        // Un exento: pasa directo a la ronda siguiente.
        next.add(home ?? away);
        continue;
      }
      final f = FixtureDraft(
        id: newId(),
        stage: FixtureStage.knockout,
        round: round,
        slot: i ~/ 2,
        homeTeamId: home.teamId,
        awayTeamId: away.teamId,
        homeSource: home.source,
        awaySource: away.source,
      );
      thisRound.add(f);
      next.add(Entrant.source(TeamSource(winnerOf: f.id)));
    }
    out.addAll(thisRound);
    if (next.length == 2) semis = thisRound;
    slots = next;
    round++;
  }
  if (thirdPlace && semis.length == 2) {
    out.add(
      FixtureDraft(
        id: newId(),
        stage: FixtureStage.third,
        round: round - 1,
        homeSource: TeamSource(loserOf: semis[0].id),
        awaySource: TeamSource(loserOf: semis[1].id),
      ),
    );
  }
  return out;
}

/// Reparte equipos sembrados en [groups] grupos (A, B, …) en serpiente: los
/// cabezas de serie quedan separados.
Map<String, List<String>> drawGroups(List<String> seeded, int groups) {
  final labels = [for (var i = 0; i < groups; i++) String.fromCharCode(65 + i)];
  final out = {for (final l in labels) l: <String>[]};
  for (final (i, team) in seeded.indexed) {
    final row = i ~/ groups;
    final col = row.isEven ? i % groups : groups - 1 - i % groups;
    out[labels[col]]!.add(team);
  }
  return out;
}

/// Grupos con todos contra todos y después un cuadro con los [advance]
/// primeros de cada uno: 1.º A contra el peor segundo, etc. (los del mismo
/// grupo no se cruzan en la primera ronda). El cuadro va con fuentes
/// `{group, pos}`: al cerrar los grupos, `stage.advance` pone los equipos.
({Map<String, List<String>> groups, List<FixtureDraft> fixtures})
groupsCupFixtures(
  List<String> seeded, {
  required String Function() newId,
  int groups = 2,
  int advance = 2,
  int legs = 1,
  bool thirdPlace = false,
}) {
  final draw = drawGroups(seeded, groups);
  final fixtures = <FixtureDraft>[];
  var lastRound = 0;
  for (final e in draw.entries) {
    final f = leagueFixtures(
      e.value,
      newId: newId,
      legs: legs,
      stage: FixtureStage.group,
      groupLabel: e.key,
    );
    fixtures.addAll(f);
    for (final x in f) {
      if (x.round > lastRound) lastRound = x.round;
    }
  }
  final entrants = [
    for (var pos = 1; pos <= advance; pos++)
      for (final g in draw.keys)
        if (draw[g]!.length >= pos)
          Entrant.source(TeamSource(group: g, pos: pos)),
  ];
  fixtures.addAll(
    cupFixtures(
      entrants,
      newId: newId,
      thirdPlace: thirdPlace,
      firstRound: lastRound + 1,
    ),
  );
  return (groups: draw, fixtures: fixtures);
}

/// Una ronda por semana desde [startsOn], a las [hour] (hora del teléfono).
void scheduleWeekly(
  List<FixtureDraft> fixtures,
  DateTime startsOn, {
  int hour = 15,
}) {
  for (final f in fixtures) {
    final day = startsOn.add(Duration(days: 7 * (f.round - 1)));
    f.startsAt = DateTime(day.year, day.month, day.day, hour);
  }
}

/// Cómo se llama una ronda de eliminatoria según cuántas faltan para la final
/// (0 es la final).
String knockoutRoundName(int fromFinal) => switch (fromFinal) {
  0 => 'Final',
  1 => 'Semifinales',
  2 => 'Cuartos de final',
  3 => 'Octavos de final',
  _ => 'Dieciseisavos',
};
