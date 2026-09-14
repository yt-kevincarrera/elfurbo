/// Reglas de negocio puras alrededor de jornadas, temporadas y admins.
library;

import '../models/app_user.dart';
import '../models/match_day.dart';
import '../models/season.dart';

const int maxRecurringWeeks = 26;

/// Fechas de una jornada que se repite cada semana a la misma hora.
/// [weeks] se acota entre 1 y [maxRecurringWeeks].
List<DateTime> weeklyDates(DateTime first, int weeks) {
  final n = weeks.clamp(1, maxRecurringWeeks);
  return List.generate(n, (i) => first.add(Duration(days: 7 * i)));
}

/// Se puede quitar el rol de admin (o bloquear) a [targetUid] solo si no es
/// el único admin activo del grupo.
bool canRemoveAdminRole(List<AppUser> users, String targetUid) {
  final target = users.where((u) => u.uid == targetUid).firstOrNull;
  if (target == null || !target.isAdmin) return true;
  final otherAdmins = users.where(
    (u) => u.uid != targetUid && u.isAdmin && u.isActive,
  );
  return otherAdmins.isNotEmpty;
}

/// Una temporada solo se borra si no tiene jornadas.
bool canDeleteSeason(Season season, List<MatchDay> matches) =>
    !matches.any((m) => m.seasonId == season.id);
