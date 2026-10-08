import { Hono } from "hono";
import { z } from "zod";
import { requireAuth } from "../auth/middleware";
import { errors } from "../http/errors";
import { PROVINCE_CODES } from "../rules/provinces";
import type { AppEnv } from "../types";
import { DIRECTORY_SELECT, directoryCard, escapeLike, findPublicClub, type DirectoryRow } from "./model";

export const directoryRoutes = new Hono<AppEnv>();

directoryRoutes.use(requireAuth);

const PAGE = 20;

const listSchema = z.object({
  q: z.string().trim().max(40).default(""),
  province: z.enum(PROVINCE_CODES).optional(),
  kind: z.enum(["group", "tournament"]).optional(),
  cursor: z.coerce.number().int().min(0).max(10_000).default(0),
});

/**
 * Los servidores y torneos públicos (spec 2.0 §6): oficiales primero, después por nivel y por la
 * última jornada. `cursor` es la posición desde la que seguir (la da `next`).
 */
directoryRoutes.get("/", async (c) => {
  const parsed = listSchema.safeParse(c.req.query());
  if (!parsed.success) throw errors.invalidInput(z.flattenError(parsed.error).fieldErrors);
  const { q, province, kind, cursor } = parsed.data;
  const like = `%${escapeLike(q.toLowerCase())}%`;
  const { results } = await c.env.DB.prepare(
    `${DIRECTORY_SELECT}
       AND (?2 = '' OR lower(c.name) LIKE ?3 ESCAPE '\\' OR lower(COALESCE(c.city, '')) LIKE ?3 ESCAPE '\\')
       AND (?4 IS NULL OR c.province = ?4)
       AND (?5 IS NULL OR c.kind = ?5)
     ORDER BY c.official DESC,
              CASE cm.tier WHEN 'verified' THEN 3 WHEN 'established' THEN 2 WHEN 'casual' THEN 1 ELSE 0 END DESC,
              COALESCE(cm.last_played_at, '') DESC, c.name, c.id
     LIMIT ?6 OFFSET ?7`,
  )
    .bind(c.var.auth.user.id, q, like, province ?? null, kind ?? null, PAGE + 1, cursor)
    .all<DirectoryRow>();
  return c.json({
    clubs: results.slice(0, PAGE).map(directoryCard),
    next: results.length > PAGE ? cursor + PAGE : null,
  });
});

/** El detalle de uno: descripción, los mejores goleadores de la temporada y las próximas jornadas. */
directoryRoutes.get("/:clubId", async (c) => {
  const db = c.env.DB;
  const row = await findPublicClub(db, c.req.param("clubId"), c.var.auth.user.id);
  const extras = row.kind === "tournament" ? await tournamentExtras(db, row.id) : await publicExtras(db, row.id);
  return c.json({ club: { ...directoryCard(row), description: row.description, ...extras } });
});

/** Lo que se enseña de un servidor público a cualquiera: también lo usa la página `/s/:id`. */
export async function publicExtras(db: D1Database, clubId: string) {
  const season = await db
    .prepare("SELECT id, name FROM seasons WHERE club_id = ? AND is_active = 1")
    .bind(clubId)
    .first<{ id: string; name: string }>();
  const { results: scorers } = season
    ? await db
        .prepare(
          `SELECT COALESCE(NULLIF(m.nickname, ''), m.display_name) AS name, ms.goals, ms.assists, ms.played
             FROM member_stats ms JOIN members m ON m.id = ms.member_id
            WHERE ms.club_id = ? AND ms.period_id = ? AND ms.played > 0
            ORDER BY ms.goals DESC, ms.assists DESC, ms.played ASC LIMIT 5`,
        )
        .bind(clubId, season.id)
        .all<{ name: string; goals: number; assists: number; played: number }>()
    : { results: [] };
  const { results: upcoming } = await db
    .prepare(
      `SELECT starts_at, place FROM matchdays
        WHERE club_id = ? AND status <> 'cancelled' AND starts_at > ? ORDER BY starts_at LIMIT 3`,
    )
    .bind(clubId, new Date().toISOString())
    .all<{ starts_at: string; place: string | null }>();
  return {
    season: season?.name ?? null,
    topScorers: scorers,
    upcoming: upcoming.map((u) => ({ startsAt: u.starts_at, place: u.place })),
  };
}

/** Lo que se enseña de un torneo público: sus equipos y, si terminó, el campeón. */
export async function tournamentExtras(db: D1Database, clubId: string) {
  const { results: teams } = await db
    .prepare("SELECT id, name, short_name, color FROM teams WHERE club_id = ? AND status = 'approved' ORDER BY name")
    .bind(clubId)
    .all<{ id: string; name: string; short_name: string; color: number }>();
  const champion = await db
    .prepare("SELECT t.name FROM awards a JOIN teams t ON t.id = a.team_id WHERE a.club_id = ? AND a.kind = 'champion'")
    .bind(clubId)
    .first<{ name: string }>();
  return {
    teams: teams.map((t) => ({ id: t.id, name: t.name, shortName: t.short_name, color: t.color })),
    champion: champion?.name ?? null,
    topScorers: [],
    upcoming: [],
    season: null,
  };
}
