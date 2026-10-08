/**
 * El job de estadísticas (spec 2.0 §3 y §4): recalcula `member_stats`, `club_metrics` y
 * `period_tiers` de los servidores con cambios nuevos, o de los que llevan más de un día sin
 * recalcular (las señales del prestigio dependen de la fecha). Corre en el cron cada 10 minutos.
 *
 * No escribe en `changes`: el nivel no viaja en el pull (va en `/me` y en sus rutas), así el job no
 * se dispara a sí mismo.
 */
import { findClub, type ClubRecord } from "../clubs/model";
import { clubSignals, prestigeReport, recentPlayers, score, tierFor, type Signals, type Tier } from "../rules/prestige";
import { playedMatchdays, statsOf, type MemberStats, type PlayedMatchday, type StatsRows } from "../rules/stats";
import { readRows } from "../sync/entities";

const DAY_MS = 24 * 60 * 60 * 1000;
/** D1 admite como mucho 100 parámetros por sentencia. */
const CHUNK = 90;

/** Lo que cuesta, en consultas, recalcular un servidor (lecturas + red + niveles + escritura). */
const QUERIES_PER_CLUB = 16;

type Candidate = {
  id: string;
  last_change: number | null;
  computed_through: number | null;
  computed_at: string | null;
  attempted_at: string | null;
};

/**
 * Los servidores que toca recalcular: primero los que tienen cambios nuevos, después los que llevan
 * más de un día. En cada grupo, el que hace más que no se intenta va primero: uno que falla siempre
 * (o que tumba la pasada) queda al final y no deja sin recalcular a los demás.
 */
export async function staleClubs(db: D1Database, now: Date) {
  const { results } = await db
    .prepare(
      `SELECT c.id, cm.computed_through, cm.computed_at, sa.at AS attempted_at,
              (SELECT MAX(ch.id) FROM changes ch WHERE ch.club_id = c.id) AS last_change
         FROM clubs c LEFT JOIN club_metrics cm ON cm.club_id = c.id LEFT JOIN stats_attempts sa ON sa.club_id = c.id
        WHERE c.status IN ('active', 'suspended') AND c.kind = 'group'`,
    )
    .all<Candidate>();
  const dayAgo = new Date(now.getTime() - DAY_MS).toISOString();
  const byAttempt = (a: Candidate, b: Candidate) => (a.attempted_at ?? "").localeCompare(b.attempted_at ?? "");
  const changed = results
    .filter((r) => r.computed_at === null || (r.last_change ?? 0) > (r.computed_through ?? 0))
    .sort(byAttempt);
  const old = results.filter((r) => !changed.includes(r) && r.computed_at! < dayAgo).sort(byAttempt);
  return [...changed, ...old].map((r) => r.id);
}

/** Recalcula los que tocan, hasta `maxClubs` o hasta gastar `budget` consultas. Devuelve cuáles. */
export async function recomputeStats(db: D1Database, now: Date, { maxClubs = 6, budget = 600 } = {}) {
  const ids = await staleClubs(db, now);
  const done: string[] = [];
  let left = budget - 1;
  for (const id of ids) {
    if (done.length >= maxClubs || left < QUERIES_PER_CLUB) break;
    left -= QUERIES_PER_CLUB;
    try {
      // Antes de calcular: si esto tumba la pasada, la próxima empieza por otro.
      await db
        .prepare("INSERT INTO stats_attempts (club_id, at) VALUES (?, ?) ON CONFLICT (club_id) DO UPDATE SET at = excluded.at")
        .bind(id, now.toISOString())
        .run();
      await recomputeClub(db, id, now);
      done.push(id);
    } catch (e) {
      // Uno que falla no frena a los demás; se reintenta en la próxima pasada.
      console.error(`stats: ${id}`, e);
    }
  }
  return done;
}

/** Todo lo que el job necesita de un servidor, con las filas en el formato del pull. */
async function loadClub(db: D1Database, club: ClubRecord) {
  const read = (entity: Parameters<typeof readRows>[2]) => readRows(db, club.id, entity, null);
  const [member, season, matchday, attendance, report, confirmation, vote] = [
    await read("member"),
    await read("season"),
    await read("matchday"),
    await read("attendance"),
    await read("report"),
    await read("confirmation"),
    await read("vote"),
  ];
  return { member, season, rows: { matchday, attendance, report, confirmation, vote } satisfies StatsRows };
}

/** Usuarios de `userIds` que son miembros activos de otro servidor activo. */
async function activeElsewhere(db: D1Database, clubId: string, userIds: string[]) {
  const found = new Set<string>();
  for (let i = 0; i < userIds.length; i += CHUNK) {
    const chunk = userIds.slice(i, i + CHUNK);
    const { results } = await db
      .prepare(
        `SELECT DISTINCT m.user_id FROM members m JOIN clubs c ON c.id = m.club_id
          WHERE m.club_id <> ? AND m.status = 'active' AND c.status = 'active' AND c.kind = 'group'
            AND m.user_id IN (${chunk.map(() => "?").join(", ")})`,
      )
      .bind(clubId, ...chunk)
      .all<{ user_id: string }>();
    for (const r of results) found.add(r.user_id);
  }
  return found;
}

/** Días de la semana (1 = lunes … 7 = domingo, en la zona del servidor) de las jornadas de los últimos 60 días. */
export function playDays(matchdays: PlayedMatchday[], timezone: string, now: Date) {
  const since = now.getTime() - 60 * DAY_MS;
  const fmt = new Intl.DateTimeFormat("en-US", { timeZone: timezone, weekday: "short" });
  const index: Record<string, number> = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
  const days = new Set<number>();
  for (const md of matchdays) {
    if (md.players.size > 0 && Date.parse(md.startsAt) >= since) days.add(index[fmt.format(new Date(md.startsAt))]!);
  }
  return [...days].sort();
}

/**
 * Marca a quien promedia más de 4 goles por jornada con 3 o más jugadas, el doble que el promedio
 * del servidor en ese período.
 */
export function flagged(stats: Map<string, MemberStats>) {
  let goals = 0;
  let played = 0;
  for (const s of stats.values()) {
    goals += s.goals;
    played += s.played;
  }
  const clubAverage = played === 0 ? 0 : goals / played;
  const out = new Set<string>();
  for (const [id, s] of stats) {
    if (s.played < 3) continue;
    const average = s.goals / s.played;
    if (average > 4 && average > 2 * clubAverage) out.add(id);
  }
  return out;
}

export async function recomputeClub(db: D1Database, clubId: string, now: Date) {
  const club = await findClub(db, clubId);
  if (!club || (club.status !== "active" && club.status !== "suspended")) return;
  const at = now.toISOString();
  // El cursor se toma antes de leer: lo que llegue mientras tanto se recalcula en la próxima pasada.
  const last = await db
    .prepare("SELECT COALESCE(MAX(id), 0) AS id FROM changes WHERE club_id = ?")
    .bind(clubId)
    .first<{ id: number }>();
  const { member, season, rows } = await loadClub(db, club);
  const settings = { reportValidation: club.settings.reportValidation, confirmationsNeeded: club.settings.confirmationsNeeded };

  const all = playedMatchdays(rows, settings, null, now);
  const accounts = new Map(member.filter((m) => m.userId).map((m) => [String(m.id), String(m.userId)]));
  const recentUsers = [...recentPlayers(all, now)].map((p) => accounts.get(p)).filter((u): u is string => !!u);
  const signals: Signals = clubSignals({
    matchdays: all,
    now,
    confirmMode: settings.reportValidation === "confirm",
    confirmationsNeeded: settings.confirmationsNeeded,
    accounts,
    elsewhere: await activeElsewhere(db, clubId, [...new Set(recentUsers)]),
  });
  const tier: Tier = tierFor(signals, club.official);
  const points = score(signals);

  const { results: tiers } = await db
    .prepare("SELECT period_id, frozen_at FROM period_tiers WHERE club_id = ?")
    .bind(clubId)
    .all<{ period_id: string; frozen_at: string | null }>();
  const isFrozen = new Set(tiers.filter((r) => r.frozen_at !== null).map((r) => r.period_id));
  const { results: existing } = await db
    .prepare("SELECT period_id, member_id FROM member_stats WHERE club_id = ?")
    .bind(clubId)
    .all<{ period_id: string; member_id: string }>();

  // Solo se escribe lo que cambió: el plan gratuito da 100.000 filas escritas al día y un servidor
  // con varias temporadas se recalcula muchas veces en una noche de jornada.
  const seasonOf = new Map(rows.matchday.map((m) => [String(m.id), String(m.seasonId)]));
  const statements: D1PreparedStatement[] = [];
  const kept = new Set<string>();
  for (const s of season) {
    const periodId = String(s.id);
    const stats = statsOf(all.filter((md) => seasonOf.get(md.id) === periodId));
    const flags = flagged(stats);
    for (const [memberId, m] of stats) {
      if (m.played === 0 && m.reports === 0) continue;
      kept.add(`${periodId}:${memberId}`);
      statements.push(
        db
          .prepare(
            `INSERT INTO member_stats (club_id, period_id, member_id, played, goals, assists, mvps, hat_tricks, best_streak,
                                       best_day_goals, reports, rejected, flag, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT (club_id, period_id, member_id) DO UPDATE SET
               played = excluded.played, goals = excluded.goals, assists = excluded.assists, mvps = excluded.mvps,
               hat_tricks = excluded.hat_tricks, best_streak = excluded.best_streak, best_day_goals = excluded.best_day_goals,
               reports = excluded.reports, rejected = excluded.rejected, flag = excluded.flag, updated_at = excluded.updated_at
             WHERE (played, goals, assists, mvps, hat_tricks, best_streak, best_day_goals, reports, rejected, flag)
                IS NOT (excluded.played, excluded.goals, excluded.assists, excluded.mvps, excluded.hat_tricks,
                        excluded.best_streak, excluded.best_day_goals, excluded.reports, excluded.rejected, excluded.flag)`,
          )
          .bind(
            clubId,
            periodId,
            memberId,
            m.played,
            m.goals,
            m.assists,
            m.mvps,
            m.hatTricks,
            m.bestStreak,
            m.bestDayGoals,
            m.reports,
            m.rejected,
            flags.has(memberId) ? 1 : 0,
            at,
          ),
      );
    }
    // Abierta: sigue al nivel del servidor. Cerrada: se congela la primera vez que se ve cerrada.
    if (s.isClosed === true) {
      if (!isFrozen.has(periodId)) {
        statements.push(
          db
            .prepare(
              `INSERT INTO period_tiers (club_id, period_id, tier, score, frozen_at) VALUES (?, ?, ?, ?, ?)
               ON CONFLICT (club_id, period_id) DO UPDATE SET tier = excluded.tier, score = excluded.score, frozen_at = excluded.frozen_at`,
            )
            .bind(clubId, periodId, tier, points, at),
        );
      }
    } else {
      statements.push(
        db
          .prepare(
            `INSERT INTO period_tiers (club_id, period_id, tier, score, frozen_at) VALUES (?, ?, ?, ?, NULL)
             ON CONFLICT (club_id, period_id) DO UPDATE SET tier = excluded.tier, score = excluded.score, frozen_at = NULL
             WHERE (tier, score, frozen_at) IS NOT (excluded.tier, excluded.score, NULL)`,
          )
          .bind(clubId, periodId, tier, points),
      );
    }
  }
  for (const e of existing) {
    if (kept.has(`${e.period_id}:${e.member_id}`)) continue;
    statements.push(
      db
        .prepare("DELETE FROM member_stats WHERE club_id = ? AND period_id = ? AND member_id = ?")
        .bind(clubId, e.period_id, e.member_id),
    );
  }
  // Las temporadas borradas no dejan nivel.
  statements.push(
    db
      .prepare("DELETE FROM period_tiers WHERE club_id = ?1 AND period_id NOT IN (SELECT id FROM seasons WHERE club_id = ?1)")
      .bind(clubId),
  );
  const lastPlayed = [...all].reverse().find((md) => md.players.size > 0);
  statements.push(
    db
      .prepare(
        `INSERT INTO club_metrics (club_id, computed_through, computed_at, tier, score, signals, play_days, active_players, last_played_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (club_id) DO UPDATE SET computed_through = excluded.computed_through, computed_at = excluded.computed_at,
           tier = excluded.tier, score = excluded.score, signals = excluded.signals, play_days = excluded.play_days,
           active_players = excluded.active_players, last_played_at = excluded.last_played_at`,
      )
      .bind(
        clubId,
        last!.id,
        at,
        tier,
        points,
        JSON.stringify(signals),
        JSON.stringify(playDays(all, club.settings.timezone, now)),
        signals.players90,
        lastPlayed?.startsAt ?? null,
      ),
  );
  await db.batch(statements);
}

/** Lo que ve el dueño en "Prestigio": su nivel, la puntuación por partes y qué le falta. */
export async function prestigeOf(db: D1Database, club: ClubRecord) {
  const row = await db
    .prepare("SELECT tier, score, signals, computed_at FROM club_metrics WHERE club_id = ?")
    .bind(club.id)
    .first<{ tier: Tier; score: number; signals: string; computed_at: string }>();
  if (!row) return { tier: club.official ? "official" : "new", score: 0, parts: [], newReason: null, computedAt: null };
  return { ...prestigeReport(JSON.parse(row.signals) as Signals, club.official), computedAt: row.computed_at };
}
