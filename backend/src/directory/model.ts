import { clubSettings } from "../clubs/model";
import { errors } from "../http/errors";
import type { Tier } from "../rules/prestige";
import { registrationOpen, type TournamentStatus } from "../rules/tournament";

/** `\`, `%` y `_` se buscan literalmente. */
export const escapeLike = (q: string) => q.replace(/[\\%_]/g, (ch) => `\\${ch}`);

export type DirectoryRow = {
  id: string;
  name: string;
  description: string;
  kind: string;
  province: string | null;
  city: string | null;
  color: number;
  official: number;
  settings: string;
  tier: Tier | null;
  play_days: string | null;
  last_played_at: string | null;
  members: number;
  my_member: string | null;
  my_pending: number;
  tournament_status: string | null;
  format: string | null;
  registration_closes_at: string | null;
  teams: number | null;
};

/** Lo que el directorio dice de un servidor público. `myStatus` es el de quien mira. */
export function directoryCard(r: DirectoryRow) {
  return {
    id: r.id,
    name: r.name,
    kind: r.kind,
    province: r.province,
    city: r.city,
    color: r.color,
    official: r.official === 1,
    tier: r.official === 1 ? "official" : (r.tier ?? "new"),
    members: r.members,
    playDays: r.play_days ? (JSON.parse(r.play_days) as number[]) : [],
    lastPlayedAt: r.last_played_at,
    joinPolicy: clubSettings(r.settings).joinPolicy,
    myStatus: r.my_member === "active" ? "member" : r.my_pending === 1 ? "pending" : "none",
    ...(r.kind === "tournament"
      ? {
          tournament: {
            status: r.tournament_status,
            format: r.format,
            teams: r.teams ?? 0,
            registrationOpen: registrationOpen(
              (r.tournament_status ?? "draft") as TournamentStatus,
              r.registration_closes_at,
              new Date(),
            ),
          },
        }
      : {}),
  };
}

/** Columnas del directorio; `?1` es el usuario que mira. */
export const DIRECTORY_SELECT = `
  SELECT c.id, c.name, c.description, c.kind, c.province, c.city, c.color, c.official, c.settings,
         cm.tier, cm.play_days, cm.last_played_at,
         (SELECT COUNT(*) FROM members m WHERE m.club_id = c.id AND m.status = 'active') AS members,
         (SELECT m.status FROM members m WHERE m.club_id = c.id AND m.user_id = ?1) AS my_member,
         EXISTS (SELECT 1 FROM join_requests j WHERE j.club_id = c.id AND j.user_id = ?1 AND j.status = 'pending') AS my_pending,
         t.status AS tournament_status, t.format, t.registration_closes_at,
         (SELECT COUNT(*) FROM teams tm WHERE tm.club_id = c.id AND tm.status = 'approved') AS teams
    FROM clubs c LEFT JOIN club_metrics cm ON cm.club_id = c.id LEFT JOIN tournaments t ON t.club_id = c.id
   WHERE c.visibility = 'public' AND c.status = 'active' AND c.delisted = 0`;

/** Un servidor público y activo, o 404 (uno privado no se confirma ni que existe). */
export async function findPublicClub(db: D1Database, clubId: string, viewerId: string) {
  const row = await db.prepare(`${DIRECTORY_SELECT} AND c.id = ?2`).bind(viewerId, clubId).first<DirectoryRow>();
  if (!row) throw errors.notFound();
  return row;
}
