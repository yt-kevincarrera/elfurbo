import 'package:cloud_firestore/cloud_firestore.dart';

/// Voto de MVP de un jugador en un partido (colección `mvpVotes`).
/// El id del documento es `{matchId}_{voterUid}`.
class MvpVote {
  const MvpVote({
    required this.matchId,
    required this.voterUid,
    required this.votedFor,
    this.createdAt,
  });

  final String matchId;
  final String voterUid;
  final String votedFor;
  final DateTime? createdAt;

  static String docId(String matchId, String voterUid) =>
      '${matchId}_$voterUid';

  factory MvpVote.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return MvpVote(
      matchId: (d['matchId'] as String?) ?? '',
      voterUid: (d['voterUid'] as String?) ?? '',
      votedFor: (d['votedFor'] as String?) ?? '',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
