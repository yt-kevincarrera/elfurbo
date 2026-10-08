/// Formato de un torneo.
enum TournamentFormat {
  league('Liga'),
  cup('Copa'),
  groupsCup('Grupos y copa');

  const TournamentFormat(this.label);

  final String label;

  String get wire => this == groupsCup ? 'groups_cup' : name;

  static TournamentFormat parse(String? wire) => switch (wire) {
    'cup' => cup,
    'groups_cup' => groupsCup,
    _ => league,
  };
}

/// En qué va el torneo.
enum TournamentStatus {
  draft('Preparando'),
  registration('Inscripción abierta'),
  inProgress('En juego'),
  finished('Terminado');

  const TournamentStatus(this.label);

  final String label;

  String get wire => this == inProgress ? 'in_progress' : name;

  static TournamentStatus parse(String? wire) => switch (wire) {
    'registration' => registration,
    'in_progress' => inProgress,
    'finished' => finished,
    _ => draft,
  };
}

/// Las reglas de un torneo (`backend/src/rules/tournament.ts`), con sus
/// valores por defecto.
class TournamentRules {
  const TournamentRules({
    this.pointsWin = 3,
    this.pointsDraw = 1,
    this.pointsLoss = 0,
    this.legs = 1,
    this.groups = 2,
    this.advancePerGroup = 2,
    this.thirdPlace = false,
    this.tiebreakers = const [
      'points',
      'goalDiff',
      'goalsFor',
      'headToHead',
      'fairPlay',
    ],
    this.yellowsForBan = 3,
    this.redBanMatches = 1,
    this.playersOnField = 7,
    this.matchMinutes = 50,
  });

  final int pointsWin;
  final int pointsDraw;
  final int pointsLoss;
  final int legs;
  final int groups;
  final int advancePerGroup;
  final bool thirdPlace;
  final List<String> tiebreakers;
  final int yellowsForBan;
  final int redBanMatches;
  final int playersOnField;
  final int matchMinutes;

  factory TournamentRules.fromCloud(Map<String, dynamic>? j) {
    const d = TournamentRules();
    int n(String k, int fallback) => (j?[k] as num?)?.toInt() ?? fallback;
    return TournamentRules(
      pointsWin: n('pointsWin', d.pointsWin),
      pointsDraw: n('pointsDraw', d.pointsDraw),
      pointsLoss: n('pointsLoss', d.pointsLoss),
      legs: n('legs', d.legs),
      groups: n('groups', d.groups),
      advancePerGroup: n('advancePerGroup', d.advancePerGroup),
      thirdPlace: (j?['thirdPlace'] as bool?) ?? d.thirdPlace,
      tiebreakers: [
        for (final t in (j?['tiebreakers'] as List?) ?? d.tiebreakers) '$t',
      ],
      yellowsForBan: n('yellowsForBan', d.yellowsForBan),
      redBanMatches: n('redBanMatches', d.redBanMatches),
      playersOnField: n('playersOnField', d.playersOnField),
      matchMinutes: n('matchMinutes', d.matchMinutes),
    );
  }
}

class Tournament {
  const Tournament({
    required this.id,
    required this.format,
    required this.status,
    required this.rules,
    this.registrationClosesAt,
    this.startsOn,
    this.maxTeams = 16,
    this.minPlayers = 5,
    this.maxPlayers = 15,
  });

  final String id;
  final TournamentFormat format;
  final TournamentStatus status;
  final TournamentRules rules;
  final DateTime? registrationClosesAt;
  final DateTime? startsOn;
  final int maxTeams;
  final int minPlayers;
  final int maxPlayers;

  /// Cualquiera puede inscribir un equipo (igual que `registrationOpen`).
  bool registrationOpen(DateTime now) =>
      status == TournamentStatus.registration &&
      (registrationClosesAt == null || now.isBefore(registrationClosesAt!));

  /// Los capitanes todavía arman su plantilla (igual que `rostersOpen`).
  bool get rostersOpen =>
      status == TournamentStatus.draft ||
      status == TournamentStatus.registration;

  factory Tournament.fromCloud(Map<String, dynamic> j) => Tournament(
    id: '${j['id']}',
    format: TournamentFormat.parse(j['format'] as String?),
    status: TournamentStatus.parse(j['status'] as String?),
    rules: TournamentRules.fromCloud(
      (j['rules'] as Map?)?.cast<String, dynamic>(),
    ),
    registrationClosesAt: DateTime.tryParse(
      '${j['registrationClosesAt']}',
    )?.toLocal(),
    startsOn: DateTime.tryParse('${j['startsOn']}'),
    maxTeams: (j['maxTeams'] as num?)?.toInt() ?? 16,
    minPlayers: (j['minPlayers'] as num?)?.toInt() ?? 5,
    maxPlayers: (j['maxPlayers'] as num?)?.toInt() ?? 15,
  );
}

enum TeamStatus {
  pending('Pendiente'),
  approved('Aprobado'),
  withdrawn('Retirado');

  const TeamStatus(this.label);

  final String label;

  static TeamStatus parse(String? wire) => TeamStatus.values.firstWhere(
    (s) => s.name == wire,
    orElse: () => TeamStatus.pending,
  );
}

class Team {
  const Team({
    required this.id,
    required this.name,
    required this.shortName,
    required this.status,
    this.color = 0,
    this.captainMemberId,
    this.representsClubId,
    this.seed,
    this.groupLabel,
  });

  final String id;
  final String name;
  final String shortName;
  final int color;
  final String? captainMemberId;
  final String? representsClubId;
  final TeamStatus status;
  final int? seed;
  final String? groupLabel;

  factory Team.fromCloud(Map<String, dynamic> j) => Team(
    id: '${j['id']}',
    name: (j['name'] as String?) ?? '',
    shortName: (j['shortName'] as String?) ?? '',
    color: (j['color'] as num?)?.toInt() ?? 0,
    captainMemberId: j['captainMemberId'] as String?,
    representsClubId: j['representsClubId'] as String?,
    status: TeamStatus.parse(j['status'] as String?),
    seed: (j['seed'] as num?)?.toInt(),
    groupLabel: j['groupLabel'] as String?,
  );
}

class TeamPlayer {
  const TeamPlayer({
    required this.teamId,
    required this.memberId,
    this.shirt,
    this.active = true,
  });

  final String teamId;
  final String memberId;
  final int? shirt;
  final bool active;

  factory TeamPlayer.fromCloud(Map<String, dynamic> j) => TeamPlayer(
    teamId: '${j['teamId']}',
    memberId: '${j['memberId']}',
    shirt: (j['shirt'] as num?)?.toInt(),
    active: j['status'] != 'removed',
  );
}
