import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import '../models/attendance.dart';
import '../models/match_day.dart';
import '../models/match_report.dart';
import '../models/mvp_vote.dart';

/// Todas las escrituras a Firestore. Las lecturas van por streams en
/// `providers.dart`. Los métodos devuelven el Future de Firestore: la UI los
/// dispara con `fireAndForget` para que funcionen offline.
class FirestoreRepo {
  FirestoreRepo(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get users =>
      _db.collection('users');
  CollectionReference<Map<String, dynamic>> get seasons =>
      _db.collection('seasons');
  CollectionReference<Map<String, dynamic>> get matches =>
      _db.collection('matches');
  CollectionReference<Map<String, dynamic>> get attendance =>
      _db.collection('attendance');
  CollectionReference<Map<String, dynamic>> get reports =>
      _db.collection('reports');
  CollectionReference<Map<String, dynamic>> get mvpVotes =>
      _db.collection('mvpVotes');

  // ---------------------------------------------------------------- usuarios

  /// Crea el perfil la primera vez que alguien entra (queda pendiente de
  /// aprobación) o refresca nombre y foto de Google en los siguientes logins.
  Future<void> ensureUserDoc(User user) async {
    final ref = users.doc(user.uid);
    final snap = await ref.get();
    final profile = <String, dynamic>{
      'displayName':
          user.displayName ?? user.email?.split('@').first ?? 'Jugador',
      'photoUrl': user.photoURL,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (!snap.exists) {
      await ref.set({
        ...profile,
        'email': user.email,
        'role': UserRole.player.name,
        'status': UserStatus.pending.name,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else {
      await ref.update(profile);
    }
  }

  Future<void> updateNickname(String uid, String nickname) =>
      users.doc(uid).update({
        'nickname': nickname.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> saveFcmToken(String uid, String token) =>
      users.doc(uid).update({'fcmToken': token});

  Future<void> setUserStatus(String uid, UserStatus status) =>
      users.doc(uid).update({'status': status.name});

  Future<void> setUserRole(String uid, UserRole role) =>
      users.doc(uid).update({'role': role.name});

  // -------------------------------------------------------------- temporadas

  /// Id nuevo para una temporada (se genera local, sirve offline).
  String newSeasonId() => seasons.doc().id;

  Future<void> createSeason({
    required String name,
    required DateTime startDate,
    required bool activate,
    required List<String> otherSeasonIds,
    String? id,
  }) async {
    final batch = _db.batch();
    final ref = id == null ? seasons.doc() : seasons.doc(id);
    batch.set(ref, {
      'name': name.trim(),
      'startDate': Timestamp.fromDate(startDate),
      'isActive': activate,
      'createdAt': FieldValue.serverTimestamp(),
    });
    if (activate) {
      for (final id in otherSeasonIds) {
        batch.update(seasons.doc(id), {'isActive': false});
      }
    }
    await batch.commit();
  }

  Future<void> activateSeason(String id, List<String> allSeasonIds) async {
    final batch = _db.batch();
    for (final other in allSeasonIds) {
      batch.update(seasons.doc(other), {'isActive': other == id});
    }
    await batch.commit();
  }

  Future<void> renameSeason(String id, String name) =>
      seasons.doc(id).update({'name': name.trim()});

  Future<void> updateSeason(
    String id, {
    required String name,
    required DateTime startDate,
  }) => seasons.doc(id).update({
    'name': name.trim(),
    'startDate': Timestamp.fromDate(startDate),
  });

  /// Cerrar una temporada congela todas sus jornadas. Si estaba activa, deja
  /// de estarlo.
  Future<void> setSeasonClosed(String id, bool closed) => seasons
      .doc(id)
      .update({'isClosed': closed, if (closed) 'isActive': false});

  /// Solo debe llamarse si la temporada no tiene jornadas (ver
  /// `canDeleteSeason`).
  Future<void> deleteSeason(String id) => seasons.doc(id).delete();

  Future<void> moveMatchesToSeason(
    Iterable<String> matchIds,
    String seasonId,
  ) async {
    final batch = _db.batch();
    for (final id in matchIds) {
      batch.update(matches.doc(id), {'seasonId': seasonId});
    }
    await batch.commit();
  }

  // ---------------------------------------------------------------- partidos

  /// Crea una jornada por cada fecha (una sola, o varias si se repite cada
  /// semana) en un mismo lote.
  Future<void> createMatches({
    required List<DateTime> dates,
    required String seasonId,
    required String createdBy,
    required int durationMinutes,
    String? place,
    String? notes,
  }) async {
    final batch = _db.batch();
    for (final date in dates) {
      batch.set(matches.doc(), {
        'date': Timestamp.fromDate(date),
        'durationMinutes': durationMinutes,
        'seasonId': seasonId,
        'status': MatchStatus.scheduled.name,
        'createdBy': createdBy,
        'place': _nullIfBlank(place),
        'notes': _nullIfBlank(notes),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  Future<void> updateMatch(
    String id, {
    required DateTime date,
    required int durationMinutes,
    required String seasonId,
    String? place,
    String? notes,
  }) => matches.doc(id).update({
    'date': Timestamp.fromDate(date),
    'durationMinutes': durationMinutes,
    'seasonId': seasonId,
    'place': _nullIfBlank(place),
    'notes': _nullIfBlank(notes),
  });

  Future<void> setMatchStatus(String id, MatchStatus status) =>
      matches.doc(id).update({'status': status.name});

  /// Borra la jornada y todo lo que cuelga de ella (asistencias, reportes y
  /// votos, cuyos ids se toman de las colecciones ya cargadas) en un lote.
  Future<void> deleteMatchCascade(
    String matchId, {
    required Iterable<String> attendanceIds,
    required Iterable<String> reportIds,
    required Iterable<String> voteIds,
  }) async {
    final batch = _db.batch();
    for (final id in attendanceIds) {
      batch.delete(attendance.doc(id));
    }
    for (final id in reportIds) {
      batch.delete(reports.doc(id));
    }
    for (final id in voteIds) {
      batch.delete(mvpVotes.doc(id));
    }
    batch.delete(matches.doc(matchId));
    await batch.commit();
  }

  Future<void> saveTeams(
    String matchId,
    List<String> teamA,
    List<String> teamB,
  ) => matches.doc(matchId).update({
    'teams': {'a': teamA, 'b': teamB},
  });

  Future<void> clearTeams(String matchId) =>
      matches.doc(matchId).update({'teams': FieldValue.delete()});

  // -------------------------------------------------------------- asistencia

  /// Intención previa (Voy / Quizás / No voy). Conserva la presencia si ya
  /// estaba marcada.
  Future<void> setAttendance(
    String matchId,
    String uid,
    AttendanceStatus status,
  ) => attendance.doc(Attendance.docId(matchId, uid)).set({
    'matchId': matchId,
    'uid': uid,
    'status': status.name,
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  /// Presencia real de un jugador en una jornada ya jugada. [setBy] es quien
  /// la marca: el propio jugador o un admin.
  Future<void> setPresence(
    String matchId,
    String uid,
    bool played, {
    required String setBy,
  }) => attendance.doc(Attendance.docId(matchId, uid)).set({
    'matchId': matchId,
    'uid': uid,
    Attendance.fieldPlayed: played,
    Attendance.fieldPlayedSetBy: setBy,
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  /// El admin pasa lista: presencia de todos los jugadores en un lote.
  Future<void> setPresenceBulk(
    String matchId,
    Map<String, bool> presenceByUid, {
    required String setBy,
  }) async {
    final batch = _db.batch();
    for (final entry in presenceByUid.entries) {
      batch.set(
        attendance.doc(Attendance.docId(matchId, entry.key)),
        {
          'matchId': matchId,
          'uid': entry.key,
          Attendance.fieldPlayed: entry.value,
          Attendance.fieldPlayedSetBy: setBy,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    }
    await batch.commit();
  }

  // ---------------------------------------------------------------- reportes

  /// Crea o reemplaza el reporte del jugador. Cualquier edición vuelve el
  /// reporte a "pendiente" (se borran las confirmaciones).
  Future<void> submitReport({
    required String matchId,
    required String uid,
    required int goals,
    required int assists,
    String? note,
  }) => reports.doc(MatchReport.docId(matchId, uid)).set({
    'matchId': matchId,
    'uid': uid,
    'goals': goals,
    'assists': assists,
    'note': _nullIfBlank(note),
    'confirmations': <String>[],
    'adminStatus': null,
    'updatedAt': FieldValue.serverTimestamp(),
  });

  Future<void> deleteReport(String reportId) => reports.doc(reportId).delete();

  /// Un compañero confirma el reporte de otro.
  Future<void> confirmReport(String reportId, String confirmerUid) =>
      reports.doc(reportId).update({
        'confirmations': FieldValue.arrayUnion([confirmerUid]),
      });

  /// Decisión del admin. `null` vuelve a dejar que decidan las confirmaciones.
  Future<void> adminSetReportStatus(String reportId, ReportStatus? status) =>
      reports.doc(reportId).update({'adminStatus': status?.name});

  // --------------------------------------------------------------------- MVP

  Future<void> voteMvp({
    required String matchId,
    required String voterUid,
    required String votedFor,
  }) => mvpVotes.doc(MvpVote.docId(matchId, voterUid)).set({
    'matchId': matchId,
    'voterUid': voterUid,
    'votedFor': votedFor,
    'createdAt': FieldValue.serverTimestamp(),
  });

  Future<void> removeMvpVote(String matchId, String voterUid) =>
      mvpVotes.doc(MvpVote.docId(matchId, voterUid)).delete();

  static String? _nullIfBlank(String? s) {
    final t = s?.trim() ?? '';
    return t.isEmpty ? null : t;
  }
}
