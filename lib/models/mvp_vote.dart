/// Voto de MVP de un jugador en una jornada (ids de miembro).
class MvpVote {
  const MvpVote({
    required this.matchId,
    required this.voterUid,
    required this.votedFor,
  });

  final String matchId;
  final String voterUid;
  final String votedFor;

  /// Una fila `vote` de la vista local.
  factory MvpVote.fromCloud(Map<String, dynamic> d) => MvpVote(
    matchId: (d['matchdayId'] as String?) ?? '',
    voterUid: (d['voterId'] as String?) ?? '',
    votedFor: (d['votedFor'] as String?) ?? '',
  );
}
