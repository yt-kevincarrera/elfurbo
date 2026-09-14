import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/stats_engine.dart';
import '../models/app_user.dart';
import '../models/attendance.dart';
import '../models/match_day.dart';
import '../models/match_report.dart';
import '../models/mvp_vote.dart';
import '../models/season.dart';
import '../services/auth_service.dart';
import '../services/push_service.dart';
import '../services/update_service.dart';
import 'firestore_repo.dart';

// ------------------------------------------------------------ infraestructura

final firestoreProvider = Provider<FirebaseFirestore>(
  (ref) => FirebaseFirestore.instance,
);
final repoProvider = Provider<FirestoreRepo>(
  (ref) => FirestoreRepo(ref.watch(firestoreProvider)),
);
final authServiceProvider = Provider<AuthService>((ref) => AuthService());
final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(ref.watch(repoProvider));
  ref.onDispose(service.dispose);
  return service;
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

// -------------------------------------------------------------------- sesión

final authStateProvider = StreamProvider<User?>(
  (ref) => ref.watch(authServiceProvider).authStateChanges,
);

/// Perfil del usuario logueado (null mientras no exista el documento).
final currentUserProvider = StreamProvider<AppUser?>((ref) {
  final user = ref.watch(authStateProvider).value;
  if (user == null) return Stream.value(null);
  return ref
      .watch(repoProvider)
      .users
      .doc(user.uid)
      .snapshots()
      .map((doc) => doc.exists ? AppUser.fromDoc(doc) : null);
});

/// Uid del usuario logueado. Solo usar dentro de la app (ya autenticado).
final myUidProvider = Provider<String>((ref) {
  return ref.watch(authStateProvider).value?.uid ?? '';
});

final isAdminProvider = Provider<bool>((ref) {
  return ref.watch(currentUserProvider).value?.isAdmin ?? false;
});

// -------------------------------------------------------------- colecciones
//
// Traemos las colecciones completas: son chicas (un grupo de amigos) y así
// Firestore las cachea enteras para trabajar offline sin queries especiales.

Stream<List<T>> _collection<T>(
  Query<Map<String, dynamic>> query,
  T Function(DocumentSnapshot<Map<String, dynamic>>) fromDoc,
) {
  return query.snapshots().map((snap) => snap.docs.map(fromDoc).toList());
}

final usersProvider = StreamProvider<List<AppUser>>((ref) {
  return _collection(
    ref.watch(repoProvider).users.orderBy('displayName'),
    AppUser.fromDoc,
  );
});

final seasonsProvider = StreamProvider<List<Season>>((ref) {
  return _collection(
    ref.watch(repoProvider).seasons.orderBy('startDate', descending: true),
    Season.fromDoc,
  );
});

final matchesProvider = StreamProvider<List<MatchDay>>((ref) {
  return _collection(
    ref.watch(repoProvider).matches.orderBy('date', descending: true),
    MatchDay.fromDoc,
  );
});

final attendanceProvider = StreamProvider<List<Attendance>>((ref) {
  return _collection(ref.watch(repoProvider).attendance, Attendance.fromDoc);
});

final reportsProvider = StreamProvider<List<MatchReport>>((ref) {
  return _collection(ref.watch(repoProvider).reports, MatchReport.fromDoc);
});

final mvpVotesProvider = StreamProvider<List<MvpVote>>((ref) {
  return _collection(ref.watch(repoProvider).mvpVotes, MvpVote.fromDoc);
});

// ---------------------------------------------------------------- derivados

final usersByIdProvider = Provider<Map<String, AppUser>>((ref) {
  final users = ref.watch(usersProvider).value ?? const [];
  return {for (final u in users) u.uid: u};
});

final activeUsersProvider = Provider<List<AppUser>>((ref) {
  final users = ref.watch(usersProvider).value ?? const [];
  return users.where((u) => u.isActive).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
});

final pendingUsersProvider = Provider<List<AppUser>>((ref) {
  final users = ref.watch(usersProvider).value ?? const [];
  return users.where((u) => u.isPending).toList();
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
  final season = ref.watch(seasonByIdProvider(match.seasonId));
  return match.isClosed(
    DateTime.now(),
    seasonClosed: season?.isClosed ?? false,
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

/// Uids con presencia real confirmada en la jornada.
final presentUidsProvider = Provider.family<Set<String>, String>((
  ref,
  matchId,
) {
  final all = ref.watch(attendanceForMatchProvider(matchId));
  return {
    for (final a in all.values)
      if (a.isPresent) a.uid,
  };
});

/// true si el usuario logueado tiene presencia real en la jornada.
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
  SeasonFilter build() => const ActiveSeasonFilter();

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

// ------------------------------------------------------------ sincronización

class SyncStatus {
  const SyncStatus({required this.fromCache, required this.pendingWrites});

  final bool fromCache;
  final bool pendingWrites;

  bool get isOnline => !fromCache;
}

/// Estado de conexión inferido de los metadatos de Firestore.
final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  return ref
      .watch(repoProvider)
      .matches
      .snapshots(includeMetadataChanges: true)
      .map(
        (snap) => SyncStatus(
          fromCache: snap.metadata.isFromCache,
          pendingWrites: snap.metadata.hasPendingWrites,
        ),
      );
});
