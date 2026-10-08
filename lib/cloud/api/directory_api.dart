import 'api_client.dart';

/// Un servidor (o torneo) público del directorio.
class DirectoryClub {
  const DirectoryClub({
    required this.id,
    required this.name,
    required this.kind,
    required this.tier,
    required this.members,
    required this.joinPolicy,
    required this.myStatus,
    this.province,
    this.city,
    this.color = 0,
    this.official = false,
    this.playDays = const [],
    this.lastPlayedAt,
  });

  final String id;
  final String name;
  final String kind;
  final String? province;
  final String? city;
  final int color;
  final bool official;
  final String tier;
  final int members;

  /// Días de la semana en que se juega (1 = lunes … 7 = domingo).
  final List<int> playDays;
  final DateTime? lastPlayedAt;

  /// `request` (lo acepta un admin) u `open` (se entra al momento).
  final String joinPolicy;

  /// `member`, `pending` o `none`.
  final String myStatus;

  bool get isTournament => kind == 'tournament';

  factory DirectoryClub.fromJson(Map<String, dynamic> j) => DirectoryClub(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: (j['kind'] as String?) ?? 'group',
    province: j['province'] as String?,
    city: j['city'] as String?,
    color: (j['color'] as num?)?.toInt() ?? 0,
    official: j['official'] == true,
    tier: (j['tier'] as String?) ?? 'new',
    members: (j['members'] as num?)?.toInt() ?? 0,
    playDays: [for (final d in (j['playDays'] as List? ?? const [])) d as int],
    lastPlayedAt: DateTime.tryParse('${j['lastPlayedAt']}')?.toLocal(),
    joinPolicy: (j['joinPolicy'] as String?) ?? 'request',
    myStatus: (j['myStatus'] as String?) ?? 'none',
  );
}

class TopScorer {
  const TopScorer(this.name, this.goals, this.assists, this.played);

  final String name;
  final int goals;
  final int assists;
  final int played;
}

/// El detalle de un servidor público.
class DirectoryDetail {
  const DirectoryDetail({
    required this.club,
    required this.description,
    required this.topScorers,
    required this.upcoming,
    this.season,
  });

  final DirectoryClub club;
  final String description;
  final String? season;
  final List<TopScorer> topScorers;
  final List<({DateTime startsAt, String? place})> upcoming;

  factory DirectoryDetail.fromJson(Map<String, dynamic> j) {
    final c = j['club'] as Map<String, dynamic>;
    return DirectoryDetail(
      club: DirectoryClub.fromJson(c),
      description: (c['description'] as String?) ?? '',
      season: c['season'] as String?,
      topScorers: [
        for (final s in (c['topScorers'] as List? ?? const []))
          TopScorer(
            '${(s as Map)['name']}',
            (s['goals'] as num).toInt(),
            (s['assists'] as num).toInt(),
            (s['played'] as num).toInt(),
          ),
      ],
      upcoming: [
        for (final u in (c['upcoming'] as List? ?? const []))
          (
            startsAt: DateTime.parse('${(u as Map)['startsAt']}').toLocal(),
            place: u['place'] as String?,
          ),
      ],
    );
  }
}

/// Una solicitud para entrar, como la ve un admin.
class JoinRequest {
  const JoinRequest({
    required this.id,
    required this.userId,
    required this.username,
    required this.displayName,
    required this.message,
    required this.createdAt,
    this.played = 0,
    this.goals = 0,
  });

  final String id;
  final String userId;
  final String username;
  final String displayName;
  final String message;
  final DateTime createdAt;

  /// Lo que lleva jugado en toda la app.
  final int played;
  final int goals;

  factory JoinRequest.fromJson(Map<String, dynamic> j) => JoinRequest(
    id: j['id'] as String,
    userId: j['userId'] as String,
    username: j['username'] as String,
    displayName: j['displayName'] as String,
    message: (j['message'] as String?) ?? '',
    createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
    played: (j['played'] as num?)?.toInt() ?? 0,
    goals: (j['goals'] as num?)?.toInt() ?? 0,
  );
}

/// El directorio de servidores públicos y pedir entrar (spec 2.0 §6). Todo
/// necesita señal.
class DirectoryApi {
  DirectoryApi(this._api);

  final ApiClient _api;

  /// Una página del directorio y la posición de la siguiente (o null).
  Future<(List<DirectoryClub>, int?)> list({
    String query = '',
    String? province,
    String? kind,
    int cursor = 0,
  }) async {
    final qs = [
      if (query.trim().isNotEmpty)
        'q=${Uri.encodeQueryComponent(query.trim())}',
      if (province != null) 'province=$province',
      if (kind != null) 'kind=$kind',
      if (cursor > 0) 'cursor=$cursor',
    ].join('&');
    final j = await _api.get('/directory${qs.isEmpty ? '' : '?$qs'}');
    return (
      [
        for (final c in (j!['clubs'] as List))
          DirectoryClub.fromJson(c as Map<String, dynamic>),
      ],
      (j['next'] as num?)?.toInt(),
    );
  }

  Future<DirectoryDetail> detail(String clubId) async =>
      DirectoryDetail.fromJson((await _api.get('/directory/$clubId'))!);

  /// `member` si entró al momento; `pending` si queda esperando a un admin.
  Future<String> join(String clubId, {String message = ''}) async {
    final j = await _api.post('/clubs/$clubId/join', {'message': message});
    return j!['status'] as String;
  }

  Future<void> cancelJoin(String clubId) => _api.delete('/clubs/$clubId/join');

  Future<List<JoinRequest>> joinRequests(String clubId) async {
    final j = await _api.get('/clubs/$clubId/join-requests');
    return [
      for (final r in (j!['requests'] as List))
        JoinRequest.fromJson(r as Map<String, dynamic>),
    ];
  }

  Future<void> accept(String clubId, String requestId) =>
      _api.post('/clubs/$clubId/join-requests/$requestId/accept');

  Future<void> reject(String clubId, String requestId, {String note = ''}) =>
      _api.post('/clubs/$clubId/join-requests/$requestId/reject', {
        'note': note,
      });
}
