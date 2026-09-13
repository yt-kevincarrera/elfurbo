import 'package:cloud_firestore/cloud_firestore.dart';

/// Temporada (colección `seasons`). Solo una puede estar activa.
class Season {
  const Season({
    required this.id,
    required this.name,
    required this.startDate,
    required this.isActive,
    this.createdAt,
  });

  final String id;
  final String name;
  final DateTime startDate;
  final bool isActive;
  final DateTime? createdAt;

  factory Season.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return Season(
      id: doc.id,
      name: (d['name'] as String?) ?? 'Temporada',
      startDate: (d['startDate'] as Timestamp?)?.toDate() ?? DateTime(2000),
      isActive: (d['isActive'] as bool?) ?? false,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
