import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/state/providers.dart';
import '../cloud/sync/club_data.dart';
import '../domain/stats_engine.dart';
import '../models/app_user.dart';
import '../models/attendance.dart';
import '../models/match_day.dart';
import '../models/match_report.dart';
import '../models/mvp_vote.dart';
import '../models/season.dart';
import '../services/update_service.dart';
import 'club_repo.dart';

// Todo lo de aquí es del servidor elegido en el selector: sale de su vista local
// (lo último del servidor con mis cambios pendientes encima), así que funciona
// igual con o sin señal.

// ------------------------------------------------------------ infraestructura

/// Escribe cambios del servidor elegido (comandos a la cola de sync).
final repoProvider = Provider<ClubRepo>((ref) {
  final club = ref.watch(currentClubProvider);
  return ClubRepo(ref.watch(cloudProvider).run, club?.id ?? '');
});

final updateServiceProvider = Provider<UpdateService>((ref) {
  final service = UpdateService();
  ref.onDispose(service.dispose);
  return service;
});

/// Versión instalada ("0.1.0"), para mostrarla en el perfil.
final appVersionProvider = FutureProvider<String>(
  (ref) => UpdateService.installedVersion(),
);

/// La vista local del servidor elegido.
final clubDataProvider = Provider<AsyncValue<ClubData>>((ref) {
  final club = ref.watch(currentClubProvider);
  if (club == null) return const AsyncLoading();
  return ref.watch(clubViewProvider(club.id));
});

/// Ajustes del servidor, con los valores por defecto del backend.
class ClubSettings {
  const ClubSettings({
    this.matchdayCreators = 'members',
    this.reportValidation = 'confirm',
    this.confirmationsNeeded = MatchReport.defaultConfirmationsNeeded,
    this.closeAfterHours = MatchDay.defaultCloseAfterHours,
  });

  /// `members` (cualquiera crea jornadas) o `staff`.
  final String matchdayCreators;

  /// `confirm` (hacen falta confirmaciones) o `trust` (cuenta al momento).
  final String reportValidation;
  final int confirmationsNeeded;
  final int closeAfterHours;

  factory ClubSettings.fromCloud(Map<String, dynamic>? s) {
    s ??= const {};
    return ClubSettings(
      matchdayCreators: (s['matchdayCreators'] as String?) ?? 'members',
      reportValidation: (s['reportValidation'] as String?) ?? 'confirm',
      confirmationsNeeded:
          (s['confirmationsNeeded'] as num?)?.toInt() ??
          MatchReport.defaultConfirmationsNeeded,
      closeAfterHours:
          (s['closeAfterHours'] as num?)?.toInt() ??
          MatchDay.defaultCloseAfterHours,
    );
  }
}

final clubSettingsProvider = Provider<ClubSettings>((ref) {
  final club = ref.watch(clubDataProvider).value?.club;
  return ClubSettings.fromCloud(
    (club?['settings'] as Map?)?.cast<String, dynamic>(),
  );
});

// -------------------------------------------------------------------- sesión

/// Mi id de miembro en el servidor elegido ('' si todavía no se sabe).
final myUidProvider = Provider<String>((ref) {
  return ref.watch(currentClubProvider)?.memberId ?? '';
});

/// Mi rol en el servidor elegido.
final myRoleProvider = Provider<UserRole>((ref) {
  final role = ref.watch(currentClubProvider)?.role;
  return UserRole.values.firstWhere(
    (r) => r.name == role,
    orElse: () => UserRole.player,
  );
});

/// owner o admin: temporadas, decidir y corregir reportes.
final isAdminProvider = Provider<bool>((ref) {
  final role = ref.watch(myRoleProvider);
  return role == UserRole.owner || role == UserRole.admin;
});

/// owner, admin o anotador: pasar lista, poner goles por otros, equipos,
/// cancelar o cerrar jornadas.
final isStaffProvider = Provider<bool>((ref) {
  return ref.watch(isAdminProvider) ||
      ref.watch(myRoleProvider) == UserRole.scorer;
});

final canCreateMatchdayProvider = Provider<bool>((ref) {
  if (ref.watch(clubReadOnlyProvider)) return false;
  if (ref.watch(isStaffProvider)) return true;
  return ref.watch(myRoleProvider) == UserRole.player &&
      ref.watch(clubSettingsProvider).matchdayCreators == 'members';
});

/// Servidor suspendido: solo se puede consultar.
final clubReadOnlyProvider = Provider<bool>((ref) {
  return ref.watch(currentClubProvider)?.status == 'suspended';
});

// -------------------------------------------------------------- colecciones

List<T> _rows<T>(
  ClubData d,
  String entity,
  T Function(Map<String, dynamic>) from,
) => [for (final r in d.all(entity)) from(r)];

final usersProvider = Provider<AsyncValue<List<AppUser>>>((ref) {
  return ref
      .watch(clubDataProvider)
      .whenData((d) => _rows(d, 'member', AppUser.fromCloud));
});

final seasonsProvider = Provider<AsyncValue<List<Season>>>((ref) {
  return ref
      .watch(clubDataProvider)
      .whenData(
        (d) =>
            _rows(d, 'season', Season.fromCloud)
              ..sort((a, b) => b.startDate.compareTo(a.startDate)),
      );
});

final matchesProvider = Provider<AsyncValue<List<MatchDay>>>((ref) {
  return ref
      .watch(clubDataProvider)
      .whenData(
        (d) =>
            _rows(d, 'matchday', MatchDay.fromCloud)
              ..sort((a, b) => b.date.compareTo(a.date)),
      );
});

final attendanceProvider = Provider<AsyncValue<List<Attendance>>>((ref) {
  return ref
      .watch(clubDataProvider)
      .whenData((d) => _rows(d, 'attendance', Attendance.fromCloud));
});

final mvpVotesProvider = Provider<AsyncValue<List<MvpVote>>>((ref) {
  return ref
      .watch(clubDataProvider)
      .whenData((d) => _rows(d, 'vote', MvpVote.fromCloud));
});

/// Reportes con su regla de "cuenta" (spec §2): solo valen las confirmaciones
/// de quienes jugaron, lo que pone el staff cuenta al momento, y en un servidor
/// que confía en los reportes también.
final reportsProvider = Provider<AsyncValue<List<MatchReport>>>((ref) {
  final settings = ref.watch(clubSettingsProvider);
  final users = ref.watch(usersByIdProvider);
  final present = ref.watch(_presentByMatchProvider);
  return ref.watch(clubDataProvider).whenData((d) {
    final confirmers = <String, List<String>>{};
    for (final c in d.all('confirmation')) {
      final match = '${c['matchdayId']}';
      final confirmer = '${c['confirmerId']}';
      if (!(present[match]?.contains(confirmer) ?? false)) continue;
      confirmers
          .putIfAbsent('$match:${c['memberId']}', () => [])
          .add(confirmer);
    }
    return [
      for (final r in d.all('report')) _report(r, confirmers, users, settings),
    ];
  });
});

MatchReport _report(
  Map<String, dynamic> r,
  Map<String, List<String>> confirmers,
  Map<String, AppUser> users,
  ClubSettings settings,
) {
  final decision = r['decision'] as String?;
  final loadedBy = r['loadedBy'] as String?;
  return MatchReport(
    matchId: '${r['matchdayId']}',
    uid: '${r['memberId']}',
    goals: (r['goals'] as num?)?.toInt() ?? 0,
    assists: (r['assists'] as num?)?.toInt() ?? 0,
    note: r['note'] as String?,
    confirmations:
        confirmers['${r['matchdayId']}:${r['memberId']}'] ?? const [],
    adminStatus: decision == null
        ? null
        : ReportStatus.values.firstWhere(
            (s) => s.name == decision,
            orElse: () => ReportStatus.pending,
          ),
    correctedBy: r['correctedBy'] as String?,
    loadedBy: loadedBy,
    autoConfirmed:
        settings.reportValidation == 'trust' ||
        (users[loadedBy]?.isStaff ?? false),
    confirmationsNeeded: settings.confirmationsNeeded,
  );
}

/// Quién jugó cada jornada (presencia real), por id de jornada.
final _presentByMatchProvider = Provider<Map<String, Set<String>>>((ref) {
  final all = ref.watch(attendanceProvider).value ?? const [];
  final out = <String, Set<String>>{};
  for (final a in all) {
    if (a.isPresent) out.putIfAbsent(a.matchId, () => {}).add(a.uid);
  }
  return out;
});

// ---------------------------------------------------------------- derivados

/// Todos los miembros, también los que se fueron: su historial sigue con su nombre.
final usersByIdProvider = Provider<Map<String, AppUser>>((ref) {
  final users = ref.watch(usersProvider).value ?? const [];
  return {for (final u in users) u.uid: u};
});

final activeUsersProvider = Provider<List<AppUser>>((ref) {
  final users = ref.watch(usersProvider).value ?? const [];
  return users.where((u) => u.isActive).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
});

/// Temporada activa. Si ninguna está marcada, la más reciente que no esté
/// cerrada; si todas están cerradas, null (habrá que crear una).
final activeSeasonProvider = Provider<Season?>((ref) {
  final seasons = ref.watch(seasonsProvider).value ?? const [];
  return seasons.where((s) => s.isActive && !s.isClosed).firstOrNull ??
      seasons.where((s) => !s.isClosed).firstOrNull;
});

final seasonByIdProvider = Provider.family<Season?, String>((ref, id) {
  final seasons = ref.watch(seasonsProvider).value ?? const [];
  return seasons.where((s) => s.id == id).firstOrNull;
});

/// true si la jornada ya no acepta cambios (ver `MatchDay.isClosed`).
final matchClosedProvider = Provider.family<bool, String>((ref, matchId) {
  final match = ref.watch(matchByIdProvider(matchId));
  if (match == null) return true;
  if (ref.watch(clubReadOnlyProvider)) return true;
  final season = ref.watch(seasonByIdProvider(match.seasonId));
  return match.isClosed(
    DateTime.now(),
    seasonClosed: season?.isClosed ?? false,
    closeAfterHours: ref.watch(clubSettingsProvider).closeAfterHours,
  );
});

final matchByIdProvider = Provider.family<MatchDay?, String>((ref, id) {
  final matches = ref.watch(matchesProvider).value ?? const [];
  return matches.where((m) => m.id == id).firstOrNull;
});

final attendanceForMatchProvider =
    Provider.family<Map<String, Attendance>, String>((ref, matchId) {
      final all = ref.watch(attendanceProvider).value ?? const [];
      return {for (final a in all.where((a) => a.matchId == matchId)) a.uid: a};
    });

/// Miembros con presencia real confirmada en la jornada.
final presentUidsProvider = Provider.family<Set<String>, String>((
  ref,
  matchId,
) {
  return ref.watch(_presentByMatchProvider)[matchId] ?? const {};
});

/// true si yo tengo presencia real en la jornada.
final iAmPresentProvider = Provider.family<bool, String>((ref, matchId) {
  final myUid = ref.watch(myUidProvider);
  return ref.watch(presentUidsProvider(matchId)).contains(myUid);
});

final reportsForMatchProvider = Provider.family<List<MatchReport>, String>((
  ref,
  matchId,
) {
  final all = ref.watch(reportsProvider).value ?? const [];
  return all.where((r) => r.matchId == matchId).toList()..sort(
    (a, b) => b.goals != a.goals
        ? b.goals.compareTo(a.goals)
        : b.assists.compareTo(a.assists),
  );
});

final votesForMatchProvider = Provider.family<List<MvpVote>, String>((
  ref,
  matchId,
) {
  final all = ref.watch(mvpVotesProvider).value ?? const [];
  return all.where((v) => v.matchId == matchId).toList();
});

// ----------------------------------------------------------- filtro de época

/// Qué período muestran las tablas: la temporada activa (por defecto), una
/// temporada puntual o el histórico completo.
sealed class SeasonFilter {
  const SeasonFilter();
}

class ActiveSeasonFilter extends SeasonFilter {
  const ActiveSeasonFilter();
}

class AllTimeFilter extends SeasonFilter {
  const AllTimeFilter();
}

class SpecificSeasonFilter extends SeasonFilter {
  const SpecificSeasonFilter(this.seasonId);
  final String seasonId;
}

class SeasonFilterNotifier extends Notifier<SeasonFilter> {
  @override
  SeasonFilter build() {
    // Otro servidor, otras temporadas: se vuelve a la activa.
    ref.watch(currentClubProvider.select((c) => c?.id));
    return const ActiveSeasonFilter();
  }

  void set(SeasonFilter filter) => state = filter;
}

final seasonFilterProvider =
    NotifierProvider<SeasonFilterNotifier, SeasonFilter>(
      SeasonFilterNotifier.new,
    );

/// Id de temporada efectivo según el filtro (null = histórico).
final effectiveSeasonIdProvider = Provider<String?>((ref) {
  final filter = ref.watch(seasonFilterProvider);
  return switch (filter) {
    ActiveSeasonFilter() => ref.watch(activeSeasonProvider)?.id,
    AllTimeFilter() => null,
    SpecificSeasonFilter(:final seasonId) => seasonId,
  };
});

final seasonFilterLabelProvider = Provider<String>((ref) {
  final id = ref.watch(effectiveSeasonIdProvider);
  if (id == null) return 'Histórico';
  final season = ref.watch(seasonByIdProvider(id));
  if (season == null) return 'Temporada';
  return season.isClosed ? '${season.name} (cerrada)' : season.name;
});

// ------------------------------------------------------------- estadísticas

/// Motor de estadísticas para el período seleccionado en las tablas.
final statsProvider = Provider<StatsEngine>((ref) {
  return StatsEngine(
    matches: ref.watch(matchesProvider).value ?? const [],
    reports: ref.watch(reportsProvider).value ?? const [],
    votes: ref.watch(mvpVotesProvider).value ?? const [],
    attendance: ref.watch(attendanceProvider).value ?? const [],
    seasonId: ref.watch(effectiveSeasonIdProvider),
  );
});

/// Motor de estadísticas del histórico completo (para valoraciones de equipos
/// y logros, que no dependen de la temporada).
final allTimeStatsProvider = Provider<StatsEngine>((ref) {
  return StatsEngine(
    matches: ref.watch(matchesProvider).value ?? const [],
    reports: ref.watch(reportsProvider).value ?? const [],
    votes: ref.watch(mvpVotesProvider).value ?? const [],
    attendance: ref.watch(attendanceProvider).value ?? const [],
  );
});
