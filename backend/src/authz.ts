/**
 * Quién puede hacer qué dentro de un servidor (spec §4). Funciones puras: el único sitio donde se
 * decide un permiso. Los endpoints y, desde el PR3, los comandos de sync preguntan aquí.
 */

export type Role = "owner" | "admin" | "scorer" | "player" | "guest";
export type InvitableRole = "player" | "scorer" | "admin";
export type MatchdayCreators = "members" | "staff";

const RANK: Record<Role, number> = { guest: 0, player: 1, scorer: 2, admin: 3, owner: 4 };

/** owner, admin o scorer. */
export const isStaff = (role: Role) => RANK[role] >= RANK.scorer;
/** owner o admin. */
export const isAdmin = (role: Role) => RANK[role] >= RANK.admin;

/** Ajustes del servidor y transferir la propiedad: solo el owner. */
export const canManageClub = (actor: Role) => actor === "owner";

/** El owner invita con cualquier rol; un admin, solo como player o scorer. */
export function canInviteAs(actor: Role, invited: InvitableRole) {
  if (actor === "owner") return true;
  return actor === "admin" && invited !== "admin";
}

/** Ver y revocar invitaciones. */
export const canManageInvites = (actor: Role) => isAdmin(actor);

/** El owner, para cualquier miembro con cuenta; un admin, solo para scorer o player. */
export function canIssueRecoveryCode(actor: Role, target: Role) {
  if (target === "guest") return false;
  if (actor === "owner") return target !== "owner";
  return actor === "admin" && (target === "scorer" || target === "player");
}

/**
 * Cambiar el rol de alguien. El owner nombra o quita admins; un admin solo mueve entre scorer y
 * player. Nadie se convierte en owner por aquí (eso es transferir), y a los sin cuenta no se les
 * cambia el rol (primero tienen que reclamar el perfil).
 */
export function canSetRole(actor: Role, target: Role, newRole: Role) {
  if (target === "owner" || newRole === "owner" || target === "guest" || newRole === "guest") return false;
  if (actor === "owner") return true;
  if (actor !== "admin") return false;
  const lower = (r: Role) => r === "scorer" || r === "player";
  return lower(target) && lower(newRole);
}

/** Expulsar: el owner a cualquiera menos a sí mismo; un admin, a scorer, player o sin cuenta. */
export function canBan(actor: Role, target: Role) {
  if (target === "owner") return false;
  if (actor === "owner") return true;
  return actor === "admin" && RANK[target] <= RANK.scorer;
}

export const canManageSeasons = (actor: Role) => isAdmin(actor);

export function canCreateMatchday(actor: Role, creators: MatchdayCreators) {
  if (isStaff(actor)) return true;
  return actor === "player" && creators === "members";
}

export function canEditMatchday(actor: Role, ctx: { isCreator: boolean }) {
  return isStaff(actor) || (actor === "player" && ctx.isCreator);
}

/** Cancelar, cerrar, reabrir, borrar o unir jornadas. */
export function canManageMatchday(actor: Role, ctx: { isCreator: boolean; hasOthersData: boolean }) {
  return isStaff(actor) || (actor === "player" && ctx.isCreator && !ctx.hasOthersData);
}

/** Pasar lista, cargar estadísticas de cualquiera, crear jugadores sin cuenta, guardar equipos. */
export const canActForOthers = (actor: Role) => isStaff(actor);

/** Confirmar, rechazar o corregir reportes. */
export const canDecideReports = (actor: Role) => isAdmin(actor);

/** Asistencia propia, reporte propio, confirmar otros, votar MVP. Todos los que tienen cuenta. */
export const canActForSelf = (actor: Role) => actor !== "guest";
