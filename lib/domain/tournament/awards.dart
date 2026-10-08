import '../../models/tournament.dart';
import 'knockout.dart';
import 'player_stats.dart';
import 'standings.dart';

/// Un premio por dar: a un equipo o a un jugador.
class AwardProposal {
  const AwardProposal(this.kind, {this.teamId, this.memberId, this.value});

  /// `champion`, `runner_up`, `third`, `top_scorer`, `top_assists`,
  /// `best_player` o `fair_play`.
  final String kind;
  final String? teamId;
  final String? memberId;
  final int? value;

  AwardProposal copyWith({String? memberId}) => AwardProposal(
    kind,
    teamId: teamId,
    memberId: memberId ?? this.memberId,
    value: value,
  );

  Map<String, Object?> toJson() => {
    'kind': kind,
    'teamId': ?teamId,
    'memberId': ?memberId,
    'value': ?value,
  };
}

/// Los premios que propone la app al terminar (spec 2.0 §7.6):
/// - campeón y subcampeón, de la final (copa) o de la tabla (liga);
/// - tercero, si se jugó el partido por el tercer puesto;
/// - bota de oro, más asistencias y mejor jugador (el de más MVP de partido);
/// - fair play: el equipo con menos tarjetas de los que jugaron.
/// El organizador puede cambiar el mejor jugador antes de confirmar.
List<AwardProposal> proposeAwards({
  required Tournament tournament,
  required List<Team> teams,
  required List<Fixture> fixtures,
  required List<FixtureEvent> events,
  required List<FixtureLineup> lineups,
}) {
  final approved = teams.where((t) => t.status == TeamStatus.approved).toList();
  final out = <AwardProposal>[];
  final finals = fixtures
      .where((f) => f.stage == FixtureStage.knockout)
      .toList();
  final lastRound = finals.fold(0, (m, f) => f.round > m ? f.round : m);
  final finalMatch = finals.where((f) => f.round == lastRound).firstOrNull;
  if (finalMatch != null && winnerOf(finalMatch) != null) {
    out
      ..add(AwardProposal('champion', teamId: winnerOf(finalMatch)))
      ..add(AwardProposal('runner_up', teamId: loserOf(finalMatch)));
  } else if (tournament.format == TournamentFormat.league) {
    final table = standings(
      teams: approved,
      fixtures: fixtures.where((f) => f.stage == FixtureStage.league),
      events: events,
      rules: tournament.rules,
    );
    if (table.isNotEmpty && table.first.played > 0) {
      out.add(AwardProposal('champion', teamId: table[0].teamId));
      if (table.length > 1) {
        out.add(AwardProposal('runner_up', teamId: table[1].teamId));
      }
    }
  }
  final third = fixtures
      .where((f) => f.stage == FixtureStage.third)
      .firstOrNull;
  if (third != null && winnerOf(third) != null) {
    out.add(AwardProposal('third', teamId: winnerOf(third)));
  }
  final stats = tournamentPlayerStats(
    fixtures: fixtures,
    events: events,
    lineups: lineups,
  );
  for (final (kind, value) in [
    ('top_scorer', (TournamentPlayerStats s) => s.goals),
    ('top_assists', (TournamentPlayerStats s) => s.assists),
    ('best_player', (TournamentPlayerStats s) => s.mvps),
  ]) {
    final best = leaders(stats, value).firstOrNull;
    if (best != null) {
      out.add(AwardProposal(kind, memberId: best.memberId, value: value(best)));
    }
  }
  // Fair play: entre los que jugaron algo, el de menos tarjetas (1 por amarilla, 3 por roja).
  // Solo los aprobados: uno que se retiró no puede llevarse un premio.
  final approvedIds = {for (final t in approved) t.id};
  final playedTeams = {
    for (final f in fixtures)
      if (f.status == FixtureStatus.played) ...[f.homeTeamId, f.awayTeamId],
  }.whereType<String>().where(approvedIds.contains);
  if (playedTeams.isNotEmpty) {
    int cards(String team) => events
        .where((e) => e.teamId == team)
        .fold(
          0,
          (n, e) =>
              n +
              switch (e.kind) {
                EventKind.yellow => 1,
                EventKind.red => 3,
                _ => 0,
              },
        );
    final fair = [...playedTeams]..sort((a, b) => cards(a).compareTo(cards(b)));
    out.add(AwardProposal('fair_play', teamId: fair.first));
  }
  return out;
}
