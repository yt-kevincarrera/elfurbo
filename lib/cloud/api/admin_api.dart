import 'api_client.dart';

// Lo que no va por la cola de sync porque necesita al servidor en el momento:
// invitaciones, códigos de recuperación, auditoría y el panel del superadmin.
// Sin señal fallan con OfflineException (la interfaz lo dice).

class Invite {
  const Invite({
    required this.code,
    required this.role,
    required this.maxUses,
    required this.uses,
    required this.expiresAt,
    this.targetMemberId,
  });

  /// "ABCD-EFGH".
  final String code;
  final String role;
  final int maxUses;
  final int uses;
  final DateTime expiresAt;

  /// Para que un jugador sin cuenta reclame su perfil.
  final String? targetMemberId;

  factory Invite.fromJson(Map<String, dynamic> j) => Invite(
    code: j['code'] as String,
    role: j['role'] as String,
    maxUses: (j['maxUses'] as num).toInt(),
    uses: (j['uses'] as num).toInt(),
    expiresAt: DateTime.parse(j['expiresAt'] as String).toLocal(),
    targetMemberId: j['targetMemberId'] as String?,
  );
}

/// Código de un solo uso para entrar sin la contraseña (dura 24 h).
class RecoveryCode {
  const RecoveryCode({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;

  factory RecoveryCode.fromJson(Map<String, dynamic> j) => RecoveryCode(
    code: j['code'] as String,
    expiresAt: DateTime.parse(j['expiresAt'] as String).toLocal(),
  );
}

class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.action,
    required this.entity,
    required this.entityKey,
    required this.summary,
    required this.at,
    this.actorName,
  });

  final int id;
  final String action;
  final String entity;
  final String entityKey;
  final Map<String, dynamic> summary;
  final DateTime at;
  final String? actorName;

  factory AuditEntry.fromJson(Map<String, dynamic> j) {
    final actor = j['actor'] as Map<String, dynamic>?;
    return AuditEntry(
      id: (j['id'] as num).toInt(),
      action: j['action'] as String,
      entity: j['entity'] as String,
      entityKey: j['entityKey'] as String,
      summary: (j['summary'] as Map?)?.cast<String, dynamic>() ?? const {},
      at: DateTime.parse(j['at'] as String).toLocal(),
      actorName:
          actor?['displayName'] as String? ?? actor?['username'] as String?,
    );
  }
}

class AuditPage {
  const AuditPage(this.entries, this.next);

  final List<AuditEntry> entries;

  /// Para pedir la página siguiente (`before`), o null si no hay más.
  final int? next;
}

/// Lo del admin de un servidor que va directo al servidor.
class ClubAdminApi {
  ClubAdminApi(this._api);

  final ApiClient _api;

  /// El enlace que se comparte (abre una página con el código).
  String inviteLink(String code) =>
      '${_api.baseUrl}/i/${code.replaceAll('-', '')}';

  Future<List<Invite>> invites(String clubId) async {
    final j = await _api.get('/clubs/$clubId/invites');
    return [
      for (final i in (j!['invites'] as List))
        Invite.fromJson(i as Map<String, dynamic>),
    ];
  }

  Future<Invite> createInvite(
    String clubId, {
    String role = 'player',
    int maxUses = 1,
    int expiresInDays = 7,
    String? targetMemberId,
  }) async {
    final j = await _api.post('/clubs/$clubId/invites', {
      'role': role,
      'maxUses': maxUses,
      'expiresInDays': expiresInDays,
      'targetMemberId': ?targetMemberId,
    });
    return Invite.fromJson(j!['invite'] as Map<String, dynamic>);
  }

  Future<void> revokeInvite(String clubId, String code) =>
      _api.post('/clubs/$clubId/invites/$code/revoke');

  Future<RecoveryCode> recoveryCode(String clubId, String memberId) async =>
      RecoveryCode.fromJson(
        (await _api.post('/clubs/$clubId/members/$memberId/recovery-code'))!,
      );

  Future<AuditPage> audit(String clubId, {int? before}) async {
    final j = await _api.get(
      '/clubs/$clubId/audit${before == null ? '' : '?before=$before'}',
    );
    return AuditPage([
      for (final e in (j!['entries'] as List))
        AuditEntry.fromJson(e as Map<String, dynamic>),
    ], (j['next'] as num?)?.toInt());
  }
}

class AdminClub {
  const AdminClub({
    required this.id,
    required this.name,
    required this.status,
    required this.requestNote,
    required this.createdAt,
    required this.members,
    this.ownerUsername,
  });

  final String id;
  final String name;

  /// `pending`, `active`, `rejected` o `suspended`.
  final String status;
  final String requestNote;
  final DateTime createdAt;
  final int members;
  final String? ownerUsername;

  factory AdminClub.fromJson(Map<String, dynamic> j) => AdminClub(
    id: j['id'] as String,
    name: j['name'] as String,
    status: j['status'] as String,
    requestNote: (j['requestNote'] as String?) ?? '',
    createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
    members: (j['members'] as num?)?.toInt() ?? 0,
    ownerUsername: j['ownerUsername'] as String?,
  );
}

class AdminUser {
  const AdminUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.status,
    required this.isSuperadmin,
    this.lastSeenAt,
  });

  final String id;
  final String username;
  final String displayName;
  final String status;
  final bool isSuperadmin;
  final DateTime? lastSeenAt;

  factory AdminUser.fromJson(Map<String, dynamic> j) => AdminUser(
    id: j['id'] as String,
    username: j['username'] as String,
    displayName: j['displayName'] as String,
    status: j['status'] as String,
    isSuperadmin: j['isSuperadmin'] == true,
    lastSeenAt: j['lastSeenAt'] == null
        ? null
        : DateTime.parse(j['lastSeenAt'] as String).toLocal(),
  );
}

class Metrics {
  const Metrics({
    required this.users,
    required this.active7d,
    required this.active30d,
    required this.clubs,
    required this.commands24h,
  });

  final int users;
  final int active7d;
  final int active30d;

  /// Servidores por estado.
  final Map<String, int> clubs;
  final int commands24h;

  factory Metrics.fromJson(Map<String, dynamic> j) {
    final u = j['users'] as Map<String, dynamic>;
    return Metrics(
      users: (u['total'] as num).toInt(),
      active7d: (u['active7d'] as num).toInt(),
      active30d: (u['active30d'] as num).toInt(),
      clubs: {
        for (final e in (j['clubs'] as Map).entries)
          '${e.key}': (e.value as num).toInt(),
      },
      commands24h: ((j['commands'] as Map?)?['last24h'] as num?)?.toInt() ?? 0,
    );
  }
}

/// El panel del superadmin (`/admin/*`).
class SuperadminApi {
  SuperadminApi(this._api);

  final ApiClient _api;

  Future<List<AdminClub>> clubs({String? status, String query = ''}) async {
    final params = [
      if (status != null) 'status=$status',
      if (query.trim().isNotEmpty)
        'q=${Uri.encodeQueryComponent(query.trim())}',
    ];
    final j = await _api.get(
      '/admin/clubs${params.isEmpty ? '' : '?${params.join('&')}'}',
    );
    return [
      for (final c in (j!['clubs'] as List))
        AdminClub.fromJson(c as Map<String, dynamic>),
    ];
  }

  Future<void> approve(String clubId) =>
      _api.post('/admin/clubs/$clubId/approve');

  Future<void> reject(String clubId, {String note = ''}) =>
      _api.post('/admin/clubs/$clubId/reject', {'note': note});

  Future<void> suspend(String clubId, {String note = ''}) =>
      _api.post('/admin/clubs/$clubId/suspend', {'note': note});

  Future<void> reactivate(String clubId) =>
      _api.post('/admin/clubs/$clubId/reactivate');

  Future<List<AdminUser>> users({String query = ''}) async {
    final q = query.trim();
    final j = await _api.get(
      '/admin/users${q.isEmpty ? '' : '?q=${Uri.encodeQueryComponent(q)}'}',
    );
    return [
      for (final u in (j!['users'] as List))
        AdminUser.fromJson(u as Map<String, dynamic>),
    ];
  }

  Future<void> suspendUser(String userId) =>
      _api.post('/admin/users/$userId/suspend');

  Future<void> unsuspendUser(String userId) =>
      _api.post('/admin/users/$userId/unsuspend');

  Future<RecoveryCode> recoveryCode(String userId) async =>
      RecoveryCode.fromJson(
        (await _api.post('/admin/users/$userId/recovery-code'))!,
      );

  Future<Metrics> metrics() async =>
      Metrics.fromJson((await _api.get('/admin/metrics'))!);
}
