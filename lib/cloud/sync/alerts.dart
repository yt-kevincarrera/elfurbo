import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../rules/matchday_rules.dart';
import 'local_store.dart';
import 'club_data.dart';

/// Avisos que salen de los datos sincronizados, sin push (spec §7): desde Cuba
/// no se puede contar con FCM (el teléfono ni consigue su token sin VPN). El
/// sync de segundo plano trae los datos cada ~15 min y el propio teléfono
/// decide qué avisar.
///
/// Cada aviso tiene una clave estable. Se guarda cuáles ya se mostraron
/// ([AlertLedger]) para no repetirlos; con la app a la vista se marcan como
/// vistos sin avisar.
enum AlertKind {
  /// Jornada nueva que creó otro.
  matchday,

  /// Un reporte de otro que puedo confirmar (jugué esa jornada).
  confirmReport,

  /// El admin rechazó mi reporte.
  reportRejected,

  /// Aprobaron mi servidor.
  clubApproved,

  /// Rechazaron mi solicitud de servidor.
  requestRejected,

  /// Superadmin: hay una solicitud de servidor nueva.
  clubRequest,
}

class Alert {
  const Alert({
    required this.key,
    required this.kind,
    required this.clubId,
    required this.clubName,
    required this.title,
    required this.body,
    this.matchdayId,
  });

  final String key;
  final AlertKind kind;
  final String clubId;
  final String clubName;
  final String title;
  final String body;
  final String? matchdayId;
}

/// Lo que ya se avisó. `seeded` es false hasta la primera pasada: esa solo
/// marca todo como visto (al instalar o actualizar no salen veinte avisos).
class AlertLedger {
  AlertLedger({this.seeded = false, Set<String>? seen}) : seen = seen ?? {};

  bool seeded;
  final Set<String> seen;

  factory AlertLedger.fromJson(Map<String, dynamic>? j) => AlertLedger(
    seeded: j?['seeded'] == true,
    seen: {for (final k in (j?['seen'] as List?) ?? const []) '$k'},
  );

  Map<String, Object?> toJson() => {'seeded': seeded, 'seen': seen.toList()};

  /// Los avisos de [current] que no se mostraron todavía, y el registro al día.
  /// Se olvida de los que ya no están (si no, crecería para siempre), salvo los
  /// que [keep] diga: los de algo que esta vez no se miró.
  List<Alert> take(
    List<Alert> current, {
    required bool notify,
    bool Function(String key)? keep,
  }) {
    final fresh = seeded && notify
        ? [
            for (final a in current)
              if (!seen.contains(a.key)) a,
          ]
        : <Alert>[];
    seen
      ..removeWhere((k) => !(keep?.call(k) ?? false))
      ..addAll(current.map((a) => a.key));
    seeded = true;
    return fresh;
  }
}

/// Los avisos que tocan ahora en un servidor para el miembro [myMemberId].
List<Alert> clubAlerts(
  ClubData data, {
  required String myMemberId,
  required DateTime now,
}) {
  final club = data.club;
  if (club == null || club['status'] != 'active') return const [];
  final clubName = '${club['name'] ?? 'tu servidor'}';
  final settings = (club['settings'] as Map?) ?? const {};
  final timezone = '${settings['timezone'] ?? 'America/Havana'}';
  final closeAfter = (settings['closeAfterHours'] as num?)?.toInt() ?? 72;
  final needed = (settings['confirmationsNeeded'] as num?)?.toInt() ?? 2;
  final trust = settings['reportValidation'] == 'trust';

  String name(Object? memberId) {
    final m = data.one('member', '$memberId');
    final nick = m?['nickname'] as String?;
    return (nick != null && nick.isNotEmpty)
        ? nick
        : '${m?['displayName'] ?? 'Alguien'}';
  }

  final seasonsClosed = {
    for (final s in data.all('season'))
      if (s['isClosed'] == true) '${s['id']}',
  };
  MatchdayTimes? times(Row? md) {
    final start = DateTime.tryParse('${md?['startsAt']}');
    if (md == null || start == null) return null;
    return MatchdayTimes(
      startsAt: start,
      durationMinutes: (md['durationMinutes'] as num?)?.toInt() ?? 0,
      status: '${md['status']}',
      seasonClosed: seasonsClosed.contains('${md['seasonId']}'),
    );
  }

  final alerts = <Alert>[];
  Alert alert(
    String key,
    AlertKind kind,
    String title,
    String body, [
    String? md,
  ]) => Alert(
    key: '$key@${data.clubId}',
    kind: kind,
    clubId: data.clubId,
    clubName: clubName,
    title: title,
    body: body,
    matchdayId: md,
  );

  // Jornadas nuevas de otros, que todavía no empezaron.
  for (final md in data.all('matchday')) {
    final t = times(md);
    if (t == null || md['createdBy'] == myMemberId) continue;
    if (data.one('attendance', '${md['id']}:$myMemberId')?['intent'] != null) {
      continue;
    }
    if (t.status == 'cancelled' || !now.isBefore(t.startsAt)) continue;
    alerts.add(
      alert(
        'md:${md['id']}',
        AlertKind.matchday,
        'Jornada nueva en $clubName',
        '${whenLabel(t.startsAt, timezone)}${_place(md)}. ¿Vas?',
        '${md['id']}',
      ),
    );
  }

  // Reportes que puedo confirmar: jugué, no es mío, nadie lo decidió y le faltan confirmaciones.
  final played = {
    for (final a in data.all('attendance'))
      if (a['memberId'] == myMemberId && a['played'] == true)
        '${a['matchdayId']}',
  };
  final confirmations = <String, int>{};
  final mine = <String>{};
  for (final c in data.all('confirmation')) {
    final report = '${c['matchdayId']}:${c['memberId']}';
    confirmations[report] = (confirmations[report] ?? 0) + 1;
    if (c['confirmerId'] == myMemberId) mine.add(report);
  }
  for (final r in data.all('report')) {
    final mdId = '${r['matchdayId']}';
    final id = '$mdId:${r['memberId']}';
    if (r['memberId'] == myMemberId) {
      if (r['decision'] == 'rejected') {
        alerts.add(
          alert(
            'rej:$id:${r['updatedAt']}',
            AlertKind.reportRejected,
            'Te rechazaron un reporte',
            'El admin de $clubName no dio por bueno tu reporte. Míralo y, si hace falta, corrígelo.',
            mdId,
          ),
        );
      }
      continue;
    }
    if (trust ||
        r['decision'] != null ||
        !played.contains(mdId) ||
        mine.contains(id)) {
      continue;
    }
    if ((confirmations[id] ?? 0) >= needed) continue;
    final t = times(data.one('matchday', mdId));
    if (t == null || !isPlayed(t, now) || isClosed(t, now, closeAfter)) {
      continue;
    }
    alerts.add(
      alert(
        // Si lo editan, sus confirmaciones se borran: hay que volver a confirmarlo.
        'rep:$id:${r['updatedAt']}',
        AlertKind.confirmReport,
        'Confirma lo de ${name(r['memberId'])}',
        '${_stats(r)} en $clubName. ¿Fue así?',
        mdId,
      ),
    );
  }
  return alerts;
}

/// Avisos de la cuenta, de `GET /me`: servidores aprobados y solicitudes rechazadas.
List<Alert> accountAlerts(Map<String, dynamic>? me) {
  if (me == null) return const [];
  return [
    for (final c in (me['clubs'] as List?) ?? const [])
      if ((c as Map)['role'] == 'owner' && c['status'] == 'active')
        Alert(
          key: 'own:${c['id']}',
          kind: AlertKind.clubApproved,
          clubId: '${c['id']}',
          clubName: '${c['name']}',
          title: '¡Aprobaron ${c['name']}!',
          body: 'Ya puedes invitar a los tuyos y crear la primera jornada.',
        ),
    for (final r in (me['clubRequests'] as List?) ?? const [])
      if ((r as Map)['status'] == 'rejected')
        Alert(
          key: 'req:${r['id']}:rejected',
          kind: AlertKind.requestRejected,
          clubId: '${r['id']}',
          clubName: '${r['name']}',
          title: 'No aprobaron ${r['name']}',
          body: '${r['reviewNote'] ?? ''}'.trim().isEmpty
              ? 'Puedes pedirlo otra vez.'
              : '${r['reviewNote']}',
        ),
  ];
}

/// Superadmin: las solicitudes pendientes (`{id, name}`).
List<Alert> requestAlerts(List<Map<String, Object?>> pending) => [
  for (final c in pending)
    Alert(
      key: 'sa:${c['id']}',
      kind: AlertKind.clubRequest,
      clubId: '${c['id']}',
      clubName: '${c['name']}',
      title: 'Solicitud de servidor nueva',
      body: '${c['name']} espera tu aprobación.',
    ),
];

/// Varios avisos del mismo tipo y servidor van en uno ("3 jornadas nuevas").
List<Alert> grouped(List<Alert> alerts) {
  final groups = <String, List<Alert>>{};
  for (final a in alerts) {
    groups.putIfAbsent('${a.kind.name}@${a.clubId}', () => []).add(a);
  }
  return [
    for (final g in groups.values)
      if (g.length == 1) g.single else _summary(g),
  ];
}

Alert _summary(List<Alert> g) {
  final a = g.first;
  final n = g.length;
  final (title, body) = switch (a.kind) {
    AlertKind.matchday => (
      '$n jornadas nuevas en ${a.clubName}',
      'Dile a los demás si vas.',
    ),
    AlertKind.confirmReport => (
      'Tienes $n reportes por confirmar',
      'En ${a.clubName}. Dale un vistazo.',
    ),
    AlertKind.reportRejected => (
      'Te rechazaron $n reportes',
      'En ${a.clubName}. Míralos y corrígelos.',
    ),
    AlertKind.clubRequest => (
      '$n solicitudes de servidor',
      'Esperan tu aprobación.',
    ),
    _ => (a.title, a.body),
  };
  return Alert(
    key: a.key,
    kind: a.kind,
    clubId: a.clubId,
    clubName: a.clubName,
    title: title,
    body: body,
  );
}

/// "Sábado 4, 16:00" en la zona del servidor. Requiere `initializeDateFormatting('es')`
/// y `tz.initializeTimeZones()`.
String whenLabel(DateTime at, String timezone) {
  tz.Location loc;
  try {
    loc = tz.getLocation(timezone);
  } catch (_) {
    loc = tz.getLocation('America/Havana');
  }
  final local = tz.TZDateTime.from(at.toUtc(), loc);
  final day = DateFormat("EEEE d, HH:mm", 'es').format(local);
  return day[0].toUpperCase() + day.substring(1);
}

String _place(Row md) {
  final place = '${md['place'] ?? ''}'.trim();
  return place.isEmpty ? '' : ' · $place';
}

String _stats(Row r) {
  final g = (r['goals'] as num?)?.toInt() ?? 0;
  final a = (r['assists'] as num?)?.toInt() ?? 0;
  String n(int x, String one, String many) => '$x ${x == 1 ? one : many}';
  if (g == 0 && a == 0) return 'Jugó sin goles ni asistencias';
  return [
    if (g > 0) n(g, 'gol', 'goles'),
    if (a > 0) n(a, 'asistencia', 'asistencias'),
  ].join(' y ');
}

/// Calcula los avisos de la cuenta con lo que hay en el teléfono y pone el
/// registro al día. Con [notify] false (la app a la vista) solo marca como
/// visto. [requests]: solicitudes pendientes si soy superadmin; null si esta
/// vez no se consultaron (se conservan sus marcas).
Future<List<Alert>> refreshAlerts(
  LocalStore store, {
  required bool notify,
  List<Map<String, Object?>>? requests,
  DateTime? now,
}) async {
  final me = await store.readMe();
  final at = now ?? DateTime.now();
  final current = <Alert>[
    ...accountAlerts(me),
    if (requests != null) ...requestAlerts(requests),
  ];
  for (final c in (me?['clubs'] as List?) ?? const []) {
    final data = await store.readClub('${(c as Map)['id']}');
    if (data == null) continue;
    current.addAll(clubAlerts(data, myMemberId: '${c['memberId']}', now: at));
  }
  final ledger = AlertLedger.fromJson(await store.readAlertLedger());
  final fresh = ledger.take(
    current,
    notify: notify,
    keep: requests == null ? (k) => k.startsWith('sa:') : null,
  );
  await store.writeAlertLedger(ledger.toJson());
  return grouped(fresh);
}
