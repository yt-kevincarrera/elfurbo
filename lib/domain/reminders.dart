/// Recordatorios locales de jornada (sin depender de Cloud Functions).
library;

import '../models/attendance.dart';
import '../models/match_day.dart';

/// Rango de ids de notificación reservado a recordatorios: dos por jornada.
const int reminderIdBase = 5000;
const int maxReminderMatches = 50;

class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    required this.matchId,
  });

  final int id;
  final DateTime at;
  final String title;
  final String body;
  final String matchId;
}

/// Recordatorios a programar para las próximas jornadas:
/// - 09:00 del día: "¡Hoy se juega!" (si esa hora todavía no pasó).
/// - 22:00 del día: "¿Cuántos metiste hoy?" (si todavía no pasó y la jornada
///   ya terminó a esa hora).
/// Se omiten las canceladas, las que quedan fuera de [horizonDays] y las
/// jornadas donde mi intención ([myIntention], por id) es "no voy".
List<PlannedReminder> plannedReminders(
  List<MatchDay> matches,
  Map<String, AttendanceStatus?> myIntention,
  DateTime now, {
  int horizonDays = 14,
}) {
  final horizon = now.add(Duration(days: horizonDays));
  DateTime nightOf(MatchDay m) =>
      DateTime(m.date.year, m.date.month, m.date.day, 22);
  final candidates =
      matches
          .where((m) => !m.isCancelled)
          // Con que quede algún aviso del día por delante alcanza.
          .where((m) => nightOf(m).isAfter(now) && m.date.isBefore(horizon))
          .where((m) => myIntention[m.id] != AttendanceStatus.no)
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));

  final out = <PlannedReminder>[];
  for (var i = 0; i < candidates.length && i < maxReminderMatches; i++) {
    final m = candidates[i];
    final morning = DateTime(m.date.year, m.date.month, m.date.day, 9);
    final night = nightOf(m);
    if (morning.isAfter(now)) {
      out.add(
        PlannedReminder(
          id: reminderIdBase + 2 * i,
          at: morning,
          title: '¡Hoy se juega!',
          body:
              'Jornada a las ${_hhmm(m.date)}'
              '${m.place != null ? ' en ${m.place}' : ''}. Marca si vas.',
          matchId: m.id,
        ),
      );
    }
    if (night.isAfter(now) && !m.end.isAfter(night)) {
      out.add(
        PlannedReminder(
          id: reminderIdBase + 2 * i + 1,
          at: night,
          title: '¿Cuántos metiste hoy?',
          body: 'Carga tus goles y asistencias, y vota al MVP de la jornada.',
          matchId: m.id,
        ),
      );
    }
  }
  return out;
}

String _two(int n) => n < 10 ? '0$n' : '$n';
String _hhmm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
