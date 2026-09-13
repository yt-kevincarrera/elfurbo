import 'package:intl/intl.dart';

/// Formateo de fechas en castellano.
class Fmt {
  static final _weekdayLong = DateFormat("EEEE d 'de' MMMM", 'es');
  static final _short = DateFormat('EEE d MMM', 'es');
  static final _dayMonth = DateFormat('d MMM', 'es');
  static final _time = DateFormat('HH:mm', 'es');
  static final _full = DateFormat("EEEE d 'de' MMMM, HH:mm", 'es');
  static final _dateOnly = DateFormat('d/M/yyyy', 'es');

  static String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String weekdayLong(DateTime d) => _cap(_weekdayLong.format(d));
  static String short(DateTime d) => _cap(_short.format(d).replaceAll('.', ''));
  static String dayMonth(DateTime d) => _dayMonth.format(d).replaceAll('.', '');
  static String time(DateTime d) => _time.format(d);
  static String full(DateTime d) => _cap(_full.format(d));
  static String dateOnly(DateTime d) => _dateOnly.format(d);

  /// "Hoy", "Mañana", "Ayer" o el día de la semana.
  static String relative(DateTime d, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return 'Hoy';
    if (diff == 1) return 'Mañana';
    if (diff == -1) return 'Ayer';
    return weekdayLong(d);
  }

  static String plural(int n, String one, String many) =>
      '$n ${n == 1 ? one : many}';
  static String goals(int n) => plural(n, 'gol', 'goles');
  static String assists(int n) => plural(n, 'asistencia', 'asistencias');
  static String decimal(double v) =>
      v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
}
