import 'package:cloud_firestore/cloud_firestore.dart';

enum MatchStatus { scheduled, cancelled }

/// Un partido (colección `matches`).
///
/// No tiene estado "jugado" explícito: se considera jugado cuando la fecha ya
/// pasó y no está cancelado.
class MatchDay {
  const MatchDay({
    required this.id,
    required this.date,
    required this.seasonId,
    required this.status,
    required this.createdBy,
    this.place,
    this.notes,
    this.teamA = const [],
    this.teamB = const [],
    this.createdAt,
  });

  final String id;
  final DateTime date;
  final String seasonId;
  final MatchStatus status;
  final String createdBy;
  final String? place;
  final String? notes;
  final List<String> teamA;
  final List<String> teamB;
  final DateTime? createdAt;

  bool get isCancelled => status == MatchStatus.cancelled;
  bool isPlayed(DateTime now) => !isCancelled && date.isBefore(now);
  bool isUpcoming(DateTime now) => !isCancelled && !date.isBefore(now);
  bool get hasTeams => teamA.isNotEmpty || teamB.isNotEmpty;

  factory MatchDay.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    final teams = (d['teams'] as Map<String, dynamic>?) ?? const {};
    return MatchDay(
      id: doc.id,
      date: (d['date'] as Timestamp?)?.toDate() ?? DateTime(2000),
      seasonId: (d['seasonId'] as String?) ?? '',
      status: MatchStatus.values.firstWhere(
        (s) => s.name == d['status'],
        orElse: () => MatchStatus.scheduled,
      ),
      createdBy: (d['createdBy'] as String?) ?? '',
      place: d['place'] as String?,
      notes: d['notes'] as String?,
      teamA: List<String>.from((teams['a'] as List?) ?? const []),
      teamB: List<String>.from((teams['b'] as List?) ?? const []),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
