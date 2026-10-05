/// Rol de un miembro en su servidor.
enum UserRole { owner, admin, scorer, player, guest }

/// Estado de un miembro: activo, se fue o lo expulsaron.
enum UserStatus { active, left, banned }

/// Un miembro de un servidor, con o sin cuenta. [uid] es su id de miembro
/// (las estadísticas cuelgan de él, así que sobreviven a reclamar el perfil).
class AppUser {
  const AppUser({
    required this.uid,
    required this.displayName,
    required this.role,
    required this.status,
    this.nickname,
    this.userId,
  });

  final String uid;
  final String displayName;
  final String? nickname;
  final UserRole role;
  final UserStatus status;

  /// Id de la cuenta, o null si es un jugador sin cuenta.
  final String? userId;

  /// Nombre a mostrar: el apodo si lo puso, si no el nombre.
  String get name {
    final nick = nickname?.trim() ?? '';
    return nick.isNotEmpty ? nick : displayName;
  }

  /// owner o admin.
  bool get isAdmin => role == UserRole.owner || role == UserRole.admin;

  /// owner, admin o anotador: pasa lista, pone goles por otros, arma equipos.
  bool get isStaff => isAdmin || role == UserRole.scorer;
  bool get isGuest => userId == null;
  bool get isActive => status == UserStatus.active;

  /// Una fila `member` de la vista local.
  factory AppUser.fromCloud(Map<String, dynamic> d) => AppUser(
    uid: '${d['id']}',
    displayName: (d['displayName'] as String?) ?? 'Jugador',
    nickname: d['nickname'] as String?,
    userId: d['userId'] as String?,
    role: UserRole.values.firstWhere(
      (r) => r.name == d['role'],
      orElse: () => UserRole.player,
    ),
    status: UserStatus.values.firstWhere(
      (s) => s.name == d['status'],
      orElse: () => UserStatus.active,
    ),
  );
}
