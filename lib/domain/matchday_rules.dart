/// Reglas de negocio puras alrededor de jornadas y temporadas.
library;

import '../models/match_day.dart';
import '../models/season.dart';

const int maxRecurringWeeks = 26;

/// Fechas de una jornada que se repite cada semana a la misma hora.
/// [weeks] se acota entre 1 y [maxRecurringWeeks].
List<DateTime> weeklyDates(DateTime first, int weeks) {
  final n = weeks.clamp(1, maxRecurringWeeks);
  return List.generate(n, (i) => first.add(Duration(days: 7 * i)));
}

/// Una temporada solo se borra si no tiene jornadas.
bool canDeleteSeason(Season season, List<MatchDay> matches) =>
    !matches.any((m) => m.seasonId == season.id);
