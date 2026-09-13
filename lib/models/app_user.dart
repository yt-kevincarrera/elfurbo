import 'package:cloud_firestore/cloud_firestore.dart';

enum UserRole { admin, player }

enum UserStatus { pending, active, blocked }

/// Perfil de un jugador del grupo (colección `users`).
class AppUser {
  const AppUser({
    required this.uid,
    required this.displayName,
    required this.role,
    required this.status,
    this.nickname,
    this.photoUrl,
    this.email,
    this.fcmToken,
    this.createdAt,
  });

  final String uid;
  final String displayName;
  final String? nickname;
  final String? photoUrl;
  final String? email;
  final UserRole role;
  final UserStatus status;
  final String? fcmToken;
  final DateTime? createdAt;

  /// Nombre a mostrar: apodo si lo cargó, si no el nombre de Google.
  String get name {
    final nick = nickname?.trim() ?? '';
    return nick.isNotEmpty ? nick : displayName;
  }

  bool get isAdmin => role == UserRole.admin;
  bool get isActive => status == UserStatus.active;
  bool get isPending => status == UserStatus.pending;

  factory AppUser.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return AppUser(
      uid: doc.id,
      displayName: (d['displayName'] as String?) ?? 'Jugador',
      nickname: d['nickname'] as String?,
      photoUrl: d['photoUrl'] as String?,
      email: d['email'] as String?,
      role: UserRole.values.firstWhere(
        (r) => r.name == d['role'],
        orElse: () => UserRole.player,
      ),
      status: UserStatus.values.firstWhere(
        (s) => s.name == d['status'],
        orElse: () => UserStatus.pending,
      ),
      fcmToken: d['fcmToken'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
