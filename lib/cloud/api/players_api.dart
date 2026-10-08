import 'api_client.dart';

/// Jornadas, goles, asistencias y MVP.
class StatTotals {
  const StatTotals({
    this.played = 0,
    this.goals = 0,
    this.assists = 0,
    this.mvps = 0,
  });

  final int played;
  final int goals;
  final int assists;
  final int mvps;

  factory StatTotals.fromJson(Map<String, dynamic>? j) => StatTotals(
    played: (j?['played'] as num?)?.toInt() ?? 0,
    goals: (j?['goals'] as num?)?.toInt() ?? 0,
    assists: (j?['assists'] as num?)?.toInt() ?? 0,
    mvps: (j?['mvps'] as num?)?.toInt() ?? 0,
  );
}

/// Lo que hizo en una temporada (o en un torneo), con el nivel con que se jugó.
class GlobalPeriod {
  const GlobalPeriod({
    required this.periodId,
    required this.name,
    required this.tier,
    required this.frozen,
    required this.stats,
    this.hatTricks = 0,
    this.flag = false,
  });

  final String periodId;
  final String name;
  final String tier;

  /// La temporada está cerrada: su nivel es el de cuando se cerró.
  final bool frozen;
  final StatTotals stats;
  final int hatTricks;

  /// Promedio fuera de lo normal en ese servidor.
  final bool flag;

  factory GlobalPeriod.fromJson(Map<String, dynamic> j) => GlobalPeriod(
    periodId: j['periodId'] as String,
    name: (j['name'] as String?) ?? '',
    tier: (j['tier'] as String?) ?? 'new',
    frozen: j['frozen'] == true,
    stats: StatTotals.fromJson(j),
    hatTricks: (j['hatTricks'] as num?)?.toInt() ?? 0,
    flag: j['flag'] == true,
  );
}

/// Un servidor (o torneo) donde jugó. Uno privado de quien mira no es
/// miembro llega sin nombre ni id.
class GlobalMembership {
  const GlobalMembership({
    required this.kind,
    required this.visibility,
    required this.official,
    required this.tier,
    required this.color,
    required this.role,
    required this.periods,
    required this.totals,
    this.clubId,
    this.name,
    this.counted = true,
  });

  /// Cuenta en los totales y el índice (false: el servidor no comparte o está
  /// suspendido; solo lo ve el propio jugador).
  final bool counted;

  final String? clubId;
  final String? name;
  final String kind;
  final String visibility;
  final bool official;
  final String tier;
  final int color;
  final String role;
  final List<GlobalPeriod> periods;
  final StatTotals totals;

  bool get hidden => name == null;

  factory GlobalMembership.fromJson(Map<String, dynamic> j) => GlobalMembership(
    clubId: j['clubId'] as String?,
    name: j['name'] as String?,
    kind: (j['kind'] as String?) ?? 'group',
    visibility: (j['visibility'] as String?) ?? 'private',
    official: j['official'] == true,
    tier: (j['tier'] as String?) ?? 'new',
    color: (j['color'] as num?)?.toInt() ?? 0,
    role: (j['role'] as String?) ?? 'player',
    periods: [
      for (final p in (j['periods'] as List? ?? const []))
        GlobalPeriod.fromJson(p as Map<String, dynamic>),
    ],
    totals: StatTotals.fromJson(j['totals'] as Map<String, dynamic>?),
    counted: j['counted'] != false,
  );
}

/// Un trofeo de torneo (la vitrina del perfil).
class Trophy {
  const Trophy({
    required this.kind,
    required this.tournament,
    this.tournamentId,
    this.at,
    this.teamName,
    this.value,
  });

  /// `champion`, `runner_up`, `third`, `top_scorer`, `top_assists`,
  /// `best_player` o `fair_play`.
  final String kind;
  final String tournament;
  final String? tournamentId;
  final DateTime? at;
  final String? teamName;
  final int? value;

  factory Trophy.fromJson(Map<String, dynamic> j) => Trophy(
    kind: j['kind'] as String,
    tournament: (j['tournament'] as String?) ?? '',
    tournamentId: j['tournamentId'] as String?,
    at: DateTime.tryParse('${j['at']}')?.toLocal(),
    teamName: j['teamName'] as String?,
    value: (j['value'] as num?)?.toInt(),
  );
}

class GlobalProfile {
  const GlobalProfile({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.memberships,
    required this.all,
    required this.trusted,
    this.since,
    this.index,
    this.trophies = const [],
    this.showPrivateStats,
  });

  final String userId;
  final String username;
  final String displayName;
  final DateTime? since;
  final List<GlobalMembership> memberships;
  final StatTotals all;

  /// Solo lo de servidores oficiales o verificados.
  final StatTotals trusted;

  /// Índice Furbo (null: todavía no hay bastante).
  final double? index;
  final List<Trophy> trophies;

  /// Solo en mi propio perfil.
  final bool? showPrivateStats;

  factory GlobalProfile.fromJson(Map<String, dynamic> j) {
    final user = j['user'] as Map<String, dynamic>;
    final totals = j['totals'] as Map<String, dynamic>? ?? const {};
    return GlobalProfile(
      userId: user['id'] as String,
      username: user['username'] as String,
      displayName: user['displayName'] as String,
      since: DateTime.tryParse('${user['since']}')?.toLocal(),
      memberships: [
        for (final m in (j['memberships'] as List? ?? const []))
          GlobalMembership.fromJson(m as Map<String, dynamic>),
      ],
      all: StatTotals.fromJson(totals['all'] as Map<String, dynamic>?),
      trusted: StatTotals.fromJson(totals['trusted'] as Map<String, dynamic>?),
      index: (j['index'] as num?)?.toDouble(),
      trophies: [
        for (final t in (j['trophies'] as List? ?? const []))
          Trophy.fromJson(t as Map<String, dynamic>),
      ],
      showPrivateStats:
          (j['settings'] as Map<String, dynamic>?)?['showPrivateStats']
              as bool?,
    );
  }
}

/// Un resultado de "Buscar jugadores".
class PlayerHit {
  const PlayerHit({
    required this.id,
    required this.username,
    required this.displayName,
  });

  final String id;
  final String username;
  final String displayName;

  factory PlayerHit.fromJson(Map<String, dynamic> j) => PlayerHit(
    id: j['id'] as String,
    username: j['username'] as String,
    displayName: j['displayName'] as String,
  );
}

/// El perfil global y la búsqueda de jugadores (`/players`), y mis ajustes de
/// privacidad (`PATCH /me`). Todo necesita señal.
class PlayersApi {
  PlayersApi(this._api);

  final ApiClient _api;

  Future<GlobalProfile> profile(String userId) async =>
      GlobalProfile.fromJson((await _api.get('/players/$userId'))!);

  Future<List<PlayerHit>> search(String query) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final j = await _api.get('/players?q=${Uri.encodeQueryComponent(q)}');
    return [
      for (final p in (j!['players'] as List))
        PlayerHit.fromJson(p as Map<String, dynamic>),
    ];
  }

  Future<void> setShowPrivateStats(bool show) =>
      _api.patch('/me', {'showPrivateStats': show});
}
