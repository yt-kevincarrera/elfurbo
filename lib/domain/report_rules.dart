import '../models/attendance.dart';
import '../models/match_day.dart';
import '../models/match_report.dart';
import '../models/mvp_vote.dart';
import 'stats_engine.dart';

typedef CloudRow = Map<String, dynamic>;

/// Los reportes de un servidor con su regla de "cuenta" (spec §2), a partir de
/// las filas del pull: solo valen las confirmaciones de quienes jugaron; lo que
/// pone o decide el staff llega con decisión "confirmado"; y en un servidor que
/// confía en los reportes ([reportValidation] `trust`), todo cuenta salvo un
/// rechazo. El backend hace lo mismo (`backend/src/rules/stats.ts`), con los
/// casos de `shared-fixtures/stats.json`.
List<MatchReport> reportsFromCloud({
  required Iterable<CloudRow> reports,
  required Iterable<CloudRow> confirmations,
  required Iterable<CloudRow> attendance,
  required String reportValidation,
  required int confirmationsNeeded,
}) {
  final present = <String>{
    for (final a in attendance)
      if (a['played'] == true) '${a['matchdayId']}:${a['memberId']}',
  };
  final confirmers = <String, List<String>>{};
  for (final c in confirmations) {
    final match = '${c['matchdayId']}';
    final confirmer = '${c['confirmerId']}';
    if (!present.contains('$match:$confirmer')) continue;
    confirmers.putIfAbsent('$match:${c['memberId']}', () => []).add(confirmer);
  }
  return [
    for (final r in reports)
      _report(
        r,
        confirmers['${r['matchdayId']}:${r['memberId']}'] ?? const [],
        trust: reportValidation == 'trust',
        needed: confirmationsNeeded,
      ),
  ];
}

MatchReport _report(
  CloudRow r,
  List<String> confirmations, {
  required bool trust,
  required int needed,
}) {
  final decision = r['decision'] as String?;
  return MatchReport(
    matchId: '${r['matchdayId']}',
    uid: '${r['memberId']}',
    goals: (r['goals'] as num?)?.toInt() ?? 0,
    assists: (r['assists'] as num?)?.toInt() ?? 0,
    note: r['note'] as String?,
    confirmations: confirmations,
    adminStatus: decision == null
        ? null
        : ReportStatus.values.firstWhere(
            (s) => s.name == decision,
            orElse: () => ReportStatus.pending,
          ),
    correctedBy: r['correctedBy'] as String?,
    loadedBy: r['loadedBy'] as String?,
    autoConfirmed: trust,
    confirmationsNeeded: needed,
  );
}

/// El motor de estadísticas a partir de las filas del pull de un servidor
/// (`matchday`, `attendance`, `report`, `confirmation`, `vote`) y sus ajustes.
StatsEngine statsFromCloud(
  Map<String, Iterable<CloudRow>> rows, {
  required Map<String, dynamic> settings,
  String? seasonId,
  DateTime? now,
}) {
  Iterable<CloudRow> all(String entity) => rows[entity] ?? const [];
  return StatsEngine(
    matches: [for (final m in all('matchday')) MatchDay.fromCloud(m)],
    reports: reportsFromCloud(
      reports: all('report'),
      confirmations: all('confirmation'),
      attendance: all('attendance'),
      reportValidation: (settings['reportValidation'] as String?) ?? 'confirm',
      confirmationsNeeded:
          (settings['confirmationsNeeded'] as num?)?.toInt() ??
          MatchReport.defaultConfirmationsNeeded,
    ),
    votes: [for (final v in all('vote')) MvpVote.fromCloud(v)],
    attendance: [for (final a in all('attendance')) Attendance.fromCloud(a)],
    seasonId: seasonId,
    now: now,
  );
}
