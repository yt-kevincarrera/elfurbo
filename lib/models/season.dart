/// Temporada de un servidor. Solo una puede estar activa. Una temporada
/// cerrada congela todas sus jornadas.
class Season {
  const Season({
    required this.id,
    required this.name,
    required this.startDate,
    required this.isActive,
    this.isClosed = false,
  });

  final String id;
  final String name;
  final DateTime startDate;
  final bool isActive;
  final bool isClosed;

  /// Una fila `season` de la vista local (`startDate` es AAAA-MM-DD).
  factory Season.fromCloud(Map<String, dynamic> d) => Season(
    id: '${d['id']}',
    name: (d['name'] as String?) ?? 'Temporada',
    startDate: DateTime.tryParse('${d['startDate']}') ?? DateTime(2000),
    isActive: d['isActive'] == true,
    isClosed: d['isClosed'] == true,
  );
}
