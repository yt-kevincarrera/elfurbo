import { Hono } from "hono";
import { requireAuth } from "../auth/middleware";
import { clubSettings } from "../clubs/model";
import { errors } from "../http/errors";
import { furboIndex } from "../rules/furbo-index";
import { TIER_RANK, type Tier } from "../rules/prestige";
import type { AppEnv } from "../types";

export const playerRoutes = new Hono<AppEnv>();

playerRoutes.use(requireAuth);

/** `\`, `%` y `_` se buscan literalmente. */
const escapeLike = (q: string) => q.replace(/[\\%_]/g, (ch) => `\\${ch}`);

/** Buscar jugadores por usuario (empieza por) o nombre (contiene). Mínimo 2 letras, hasta 20. */
playerRoutes.get("/", async (c) => {
  const q = (c.req.query("q") ?? "").trim().toLowerCase();
  if (q.length < 2) return c.json({ players: [] });
  const { results } = await c.env.DB.prepare(
    `SELECT id, username, display_name FROM users
      WHERE status = 'active' AND (username LIKE ?1 ESCAPE '\\' OR lower(display_name) LIKE ?2 ESCAPE '\\')
      ORDER BY username LIMIT 20`,
  )
    .bind(`${escapeLike(q)}%`, `%${escapeLike(q)}%`)
    .all<{ id: string; username: string; display_name: string }>();
  return c.json({ players: results.map((r) => ({ id: r.id, username: r.username, displayName: r.display_name })) });
});

type MembershipRow = {
  member_id: string;
  role: string;
  club_id: string;
  name: string;
  kind: string;
  visibility: string;
  official: number;
  color: number;
  settings: string;
  club_status: string;
  current_tier: Tier | null;
};

type StatsRow = {
  club_id: string;
  period_id: string;
  played: number;
  goals: number;
  assists: number;
  mvps: number;
  hat_tricks: number;
  flag: number;
  tier: Tier | null;
  frozen_at: string | null;
  season_name: string;
  start_date: string;
};

const CHUNK = 90;

type Totals = { played: number; goals: number; assists: number; mvps: number };
const zero = (): Totals => ({ played: 0, goals: 0, assists: 0, mvps: 0 });
const add = (t: Totals, p: Totals) => {
  t.played += p.played;
  t.goals += p.goals;
  t.assists += p.assists;
  t.mvps += p.mvps;
};

/**
 * El perfil global de un jugador (spec 2.0 §5): lo que hizo en cada servidor, con el nivel con que
 * lo hizo, los totales, el Índice Furbo y sus trofeos. Respeta la privacidad:
 * - un servidor que no comparte (`shareStats`) no sale, salvo para el propio jugador;
 * - uno privado sale sin nombre a quien no es miembro, o no sale si el jugador lo pidió.
 */
playerRoutes.get("/:userId", async (c) => {
  const db = c.env.DB;
  const viewer = c.var.auth.user;
  const user = await db
    .prepare("SELECT id, username, display_name, created_at, show_private_stats FROM users WHERE id = ?")
    .bind(c.req.param("userId"))
    .first<{ id: string; username: string; display_name: string; created_at: string; show_private_stats: number }>();
  if (!user) throw errors.notFound();
  const self = user.id === viewer.id;

  const { results: memberships } = await db
    .prepare(
      `SELECT m.id AS member_id, m.role, c.id AS club_id, c.name, c.kind, c.visibility, c.official, c.color, c.settings,
              c.status AS club_status, cm.tier AS current_tier
         FROM members m JOIN clubs c ON c.id = m.club_id LEFT JOIN club_metrics cm ON cm.club_id = c.id
        WHERE m.user_id = ? AND c.status IN ('active', 'suspended')`,
    )
    .bind(user.id)
    .all<MembershipRow>();
  const { results: mine } = await db
    .prepare("SELECT club_id FROM members WHERE user_id = ? AND status = 'active'")
    .bind(viewer.id)
    .all<{ club_id: string }>();
  const viewerClubs = new Set(mine.map((r) => r.club_id));

  // Cuenta (en los totales y el índice) lo de servidores activos que comparten: lo mismo para todos,
  // también para el propio jugador. Él ve además lo demás, marcado como que no cuenta.
  const counted = (m: MembershipRow) => clubSettings(m.settings).shareStats && m.club_status === "active";
  const visible = memberships.filter((m) => {
    if (self) return true;
    if (!counted(m)) return false;
    if (m.visibility === "public" || viewerClubs.has(m.club_id)) return true;
    return user.show_private_stats === 1;
  });

  const stats: StatsRow[] = [];
  const memberIds = visible.map((m) => m.member_id);
  for (let i = 0; i < memberIds.length; i += CHUNK) {
    const chunk = memberIds.slice(i, i + CHUNK);
    const { results } = await db
      .prepare(
        `SELECT ms.club_id, ms.period_id, ms.played, ms.goals, ms.assists, ms.mvps, ms.hat_tricks, ms.flag,
                pt.tier, pt.frozen_at, s.name AS season_name, s.start_date
           FROM member_stats ms
           LEFT JOIN period_tiers pt ON pt.club_id = ms.club_id AND pt.period_id = ms.period_id
           JOIN seasons s ON s.id = ms.period_id
          WHERE ms.member_id IN (${chunk.map(() => "?").join(", ")}) AND ms.played > 0
          ORDER BY s.start_date DESC, ms.period_id`,
      )
      .bind(...chunk)
      .all<StatsRow>();
    stats.push(...results);
  }

  const all = zero();
  const trusted = zero();
  const indexPeriods: Parameters<typeof furboIndex>[0] = [];
  const out = [];
  let anonymous = 0;
  for (const m of visible) {
    const current: Tier = m.official === 1 ? "official" : (m.current_tier ?? "new");
    // Un privado de quien mira no es miembro: sin nombre, y sin nada que lo identifique (ni el
    // nombre ni el id de sus temporadas, que podrían delatarlo o cruzarse entre perfiles).
    const named = self || m.visibility === "public" || viewerClubs.has(m.club_id);
    const periods = stats
      .filter((s) => s.club_id === m.club_id)
      .map((s) => {
        // Congelado: el de entonces. Abierto: el de ahora (oficial manda al momento).
        const tier: Tier = s.frozen_at ? s.tier! : m.official === 1 ? "official" : (s.tier ?? current);
        return {
          periodId: named ? s.period_id : `p${anonymous++}`,
          name: named ? s.season_name : `Temporada ${s.start_date.slice(0, 4)}`,
          tier,
          frozen: s.frozen_at !== null,
          played: s.played,
          goals: s.goals,
          assists: s.assists,
          mvps: s.mvps,
          hatTricks: s.hat_tricks,
          flag: s.flag === 1,
        };
      });
    if (periods.length === 0) continue;
    const totals = zero();
    const counts = counted(m);
    for (const p of periods) {
      add(totals, p);
      if (!counts) continue;
      add(all, p);
      if (TIER_RANK[p.tier] >= TIER_RANK.verified) add(trusted, p);
      indexPeriods.push(p);
    }
    out.push({
      clubId: named ? m.club_id : null,
      name: named ? m.name : null,
      kind: m.kind,
      visibility: m.visibility,
      official: m.official === 1,
      tier: current,
      color: m.color,
      role: m.role,
      counted: counts,
      periods,
      totals,
    });
  }
  // Primero lo que más pesa; a igual nivel, donde más jugó.
  out.sort((a, b) => TIER_RANK[b.tier] - TIER_RANK[a.tier] || b.totals.played - a.totals.played);

  return c.json({
    user: { id: user.id, username: user.username, displayName: user.display_name, since: user.created_at },
    memberships: out,
    totals: { all, trusted },
    index: furboIndex(indexPeriods),
    trophies: [],
    ...(self ? { settings: { showPrivateStats: user.show_private_stats === 1 } } : {}),
  });
});
