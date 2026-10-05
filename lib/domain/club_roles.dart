import '../models/app_user.dart';

// Lo mismo que `backend/src/authz.ts`, para enseñar solo lo que el servidor
// va a aceptar. Si cambias una regla aquí, cámbiala allí (y sus tests).

const _rank = {
  UserRole.guest: 0,
  UserRole.player: 1,
  UserRole.scorer: 2,
  UserRole.admin: 3,
  UserRole.owner: 4,
};

/// Cambiar el rol de alguien. El owner nombra o quita admins; un admin solo
/// mueve entre anotador y jugador. Nadie pasa a owner por aquí (eso es
/// transferir), y a los sin cuenta no se les cambia el rol.
bool canSetRole(UserRole actor, UserRole target, UserRole newRole) {
  const fixed = {UserRole.owner, UserRole.guest};
  if (fixed.contains(target) || fixed.contains(newRole)) return false;
  if (actor == UserRole.owner) return true;
  if (actor != UserRole.admin) return false;
  bool lower(UserRole r) => r == UserRole.scorer || r == UserRole.player;
  return lower(target) && lower(newRole);
}

/// Expulsar: el owner a cualquiera menos a sí mismo; un admin, a anotadores,
/// jugadores y sin cuenta.
bool canBan(UserRole actor, UserRole target) {
  if (target == UserRole.owner) return false;
  if (actor == UserRole.owner) return true;
  return actor == UserRole.admin && _rank[target]! <= _rank[UserRole.scorer]!;
}
