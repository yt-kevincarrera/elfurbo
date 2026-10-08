import type { MatchdayCreators, Role } from "../authz";
import { errors } from "../http/errors";

export type ClubStatus = "pending" | "active" | "rejected" | "suspended";
export type ClubKind = "group" | "tournament";
export type ClubVisibility = "private" | "public";
export type MemberStatus = "active" | "left" | "banned";

export type ClubSettings = {
  matchdayCreators: MatchdayCreators;
  reportValidation: "confirm" | "trust";
  confirmationsNeeded: number;
  closeAfterHours: number;
  timezone: string;
  /** Cómo se entra en un servidor público: pidiéndolo (lo acepta un admin) o al momento. */
  joinPolicy: "request" | "open";
  /** Si sus estadísticas salen en el perfil global de sus jugadores. */
  shareStats: boolean;
  /** Cupo por defecto de las jornadas nuevas (0 = sin límite). */
  maxPlayers: number;
};

export const DEFAULT_SETTINGS: ClubSettings = {
  matchdayCreators: "members",
  reportValidation: "confirm",
  confirmationsNeeded: 2,
  closeAfterHours: 72,
  timezone: "America/Havana",
  joinPolicy: "request",
  shareStats: true,
  maxPlayers: 0,
};

export type ClubRecord = {
  id: string;
  name: string;
  description: string;
  status: ClubStatus;
  ownerUserId: string;
  settings: ClubSettings;
  kind: ClubKind;
  visibility: ClubVisibility;
  official: boolean;
  province: string | null;
  city: string | null;
  /** Índice de la paleta de tiza (0–7). */
  color: number;
  /** El servidor que organiza un torneo. */
  hostClubId: string | null;
  /** El superadmin lo sacó del directorio: no se puede volver a hacer público. */
  delisted: boolean;
};

export type MemberRecord = {
  id: string;
  clubId: string;
  userId: string | null;
  role: Role;
  status: MemberStatus;
  displayName: string;
};

type ClubRow = {
  id: string;
  name: string;
  description: string;
  status: ClubStatus;
  owner_user_id: string;
  settings: string;
  kind: ClubKind;
  visibility: ClubVisibility;
  official: number;
  province: string | null;
  city: string | null;
  color: number;
  host_club_id: string | null;
  delisted: number;
};

type MemberRow = {
  id: string;
  club_id: string;
  user_id: string | null;
  role: Role;
  status: MemberStatus;
  display_name: string;
};

export const CLUB_COLUMNS =
  "id, name, description, status, owner_user_id, settings, kind, visibility, official, province, city, color, host_club_id, delisted";

export const clubSettings = (raw: string): ClubSettings => ({
  ...DEFAULT_SETTINGS,
  ...(JSON.parse(raw) as Partial<ClubSettings>),
});

export const clubFromRow = (r: ClubRow): ClubRecord => ({
  id: r.id,
  name: r.name,
  description: r.description,
  status: r.status,
  ownerUserId: r.owner_user_id,
  settings: clubSettings(r.settings),
  kind: r.kind,
  visibility: r.visibility,
  official: r.official === 1,
  province: r.province,
  city: r.city,
  color: r.color,
  hostClubId: r.host_club_id,
  delisted: r.delisted === 1,
});

const memberFromRow = (r: MemberRow): MemberRecord => ({
  id: r.id,
  clubId: r.club_id,
  userId: r.user_id,
  role: r.role,
  status: r.status,
  displayName: r.display_name,
});

export async function findClub(db: D1Database, clubId: string) {
  const row = await db.prepare(`SELECT ${CLUB_COLUMNS} FROM clubs WHERE id = ?`).bind(clubId).first<ClubRow>();
  return row ? clubFromRow(row) : null;
}

const MEMBER_COLUMNS = "id, club_id, user_id, role, status, display_name";

export async function findMember(db: D1Database, clubId: string, memberId: string) {
  const row = await db
    .prepare(`SELECT ${MEMBER_COLUMNS} FROM members WHERE club_id = ? AND id = ?`)
    .bind(clubId, memberId)
    .first<MemberRow>();
  return row ? memberFromRow(row) : null;
}

export async function findMemberByUser(db: D1Database, clubId: string, userId: string) {
  const row = await db
    .prepare(`SELECT ${MEMBER_COLUMNS} FROM members WHERE club_id = ? AND user_id = ?`)
    .bind(clubId, userId)
    .first<MemberRow>();
  return row ? memberFromRow(row) : null;
}

/**
 * El usuario tiene que ser miembro activo de un servidor activo o suspendido. Si no, 404: a
 * quien no es miembro no se le confirma ni que el servidor existe.
 */
export async function requireMembership(db: D1Database, clubId: string, userId: string) {
  const club = await findClub(db, clubId);
  if (!club || (club.status !== "active" && club.status !== "suspended")) throw errors.notFound();
  const member = await findMemberByUser(db, clubId, userId);
  if (!member || member.status !== "active") throw errors.notFound();
  return { club, member };
}

/** Para cambiar algo: además, el servidor no puede estar suspendido. */
export function assertWritable(club: ClubRecord) {
  if (club.status === "suspended") throw errors.clubSuspended();
}
