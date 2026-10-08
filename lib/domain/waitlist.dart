import '../models/attendance.dart';

/// Quién está dentro y quién en espera en una jornada con cupo (spec 2.0
/// §8.2). Los primeros [maxPlayers] que dijeron "Voy", por la hora en que lo
/// dijeron, están dentro; el resto espera en ese orden. Sin cupo (0), todos
/// dentro. Se calcula en la vista, no se guarda: si alguien se baja, sube el
/// siguiente.
({List<String> inside, List<String> waiting}) waitlist(
  Iterable<Attendance> attendance,
  int maxPlayers,
) {
  final going = attendance
      .where((a) => a.status == AttendanceStatus.yes)
      .toList();
  // Sin hora (dicho antes de la 2.0) va primero; empate, por id para que
  // todos los teléfonos vean lo mismo.
  going.sort((a, b) {
    final x = a.intentAt;
    final y = b.intentAt;
    if (x == null && y != null) return -1;
    if (x != null && y == null) return 1;
    final byTime = x == null ? 0 : x.compareTo(y!);
    return byTime != 0 ? byTime : a.uid.compareTo(b.uid);
  });
  final ids = [for (final a in going) a.uid];
  if (maxPlayers <= 0 || ids.length <= maxPlayers) {
    return (inside: ids, waiting: const []);
  }
  return (inside: ids.sublist(0, maxPlayers), waiting: ids.sublist(maxPlayers));
}
