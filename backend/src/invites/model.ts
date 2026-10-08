import type { InvitableRole } from "../authz";
import { normalizeCode } from "../auth/crypto";
import type { ClubStatus } from "../clubs/model";

export type InviteRecord = {
  code: string;
  clubId: string;
  role: InvitableRole;
  targetMemberId: string | null;
  /** Invitación de equipo (torneos). */
  teamId: string | null;
  maxUses: number;
  uses: number;
  expiresAt: string;
  revokedAt: string | null;
  club: { name: string; description: string; status: ClubStatus };
};

type InviteRow = {
  code: string;
  club_id: string;
  role: InvitableRole;
  target_member_id: string | null;
  team_id: string | null;
  max_uses: number;
  uses: number;
  expires_at: string;
  revoked_at: string | null;
  club_name: string;
  club_description: string;
  club_status: ClubStatus;
};

/** Busca la invitación tal como la escriba la gente (minúsculas, guiones, espacios). */
export async function findInvite(db: D1Database, rawCode: string) {
  const row = await db
    .prepare(
      `SELECT i.code, i.club_id, i.role, i.target_member_id, i.team_id, i.max_uses, i.uses, i.expires_at, i.revoked_at,
              c.name AS club_name, c.description AS club_description, c.status AS club_status
         FROM invites i JOIN clubs c ON c.id = i.club_id
        WHERE i.code = ?`,
    )
    .bind(normalizeCode(rawCode))
    .first<InviteRow>();
  if (!row) return null;
  return {
    code: row.code,
    clubId: row.club_id,
    role: row.role,
    targetMemberId: row.target_member_id,
    teamId: row.team_id,
    maxUses: row.max_uses,
    uses: row.uses,
    expiresAt: row.expires_at,
    revokedAt: row.revoked_at,
    club: { name: row.club_name, description: row.club_description, status: row.club_status },
  } satisfies InviteRecord;
}

/** Sirve si no está revocada ni caducada, le quedan usos y el servidor está activo. */
export function isUsable(invite: InviteRecord, now: Date) {
  return (
    invite.revokedAt === null &&
    invite.expiresAt > now.toISOString() &&
    invite.uses < invite.maxUses &&
    invite.club.status === "active"
  );
}

export function formatCode(code: string) {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}
