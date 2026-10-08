/**
 * Estadísticas y nivel de un torneo (spec 2.0 §7.7). El período es el torneo entero
 * (`period_id = club_id`). Jugó = está en la alineación de un partido jugado; goles, asistencias,
 * MVP y tarjetas, de los eventos. El nivel: oficial si lo marcó el superadmin; con 4 equipos
 * aprobados o más, el del anfitrión si es oficial o verificado (Verificado) o Establecido; si no,
 * Casual. Se congela al terminar el torneo.
 */
import type { ClubRecord } from "../clubs/model";
import { TIER_RANK, type Tier } from "../rules/prestige";
import { readRows } from "../sync/entities";

type Totals = { played: number; goals: number; assists: number; mvps: number; yellows: number; reds: number };

export function tournamentTier(official: boolean, approvedTeams: number, hostTier: Tier | null): Tier {
  if (official) return "official";
  if (approvedTeams < 4) return "casual";
  return hostTier && TIER_RANK[hostTier] >= TIER_RANK.verified ? "verified" : "established";
}

export async function recomputeTournament(db: D1Database, club: ClubRecord, now: Date) {
  const at = now.toISOString();
  const last = await db.prepare("SELECT COALESCE(MAX(id), 0) AS id FROM changes WHERE club_id = ?").bind(club.id).first<{ id: number }>();
  const [tournament, teams, fixtures, events, lineups] = [
    await db.prepare("SELECT status FROM tournaments WHERE club_id = ?").bind(club.id).first<{ status: string }>(),
    await readRows(db, club.id, "team", null),
    await readRows(db, club.id, "fixture", null),
    await readRows(db, club.id, "fixtureEvent", null),
    await readRows(db, club.id, "fixtureLineup", null),
  ];
  const host = club.hostClubId
    ? await db
        .prepare(
          "SELECT CASE WHEN c.official = 1 THEN 'official' ELSE cm.tier END AS tier FROM clubs c LEFT JOIN club_metrics cm ON cm.club_id = c.id WHERE c.id = ?",
        )
        .bind(club.hostClubId)
        .first<{ tier: Tier | null }>()
    : null;
  const approved = teams.filter((t) => t.status === "approved").length;
  const tier = tournamentTier(club.official, approved, host?.tier ?? null);

  const played = new Set(fixtures.filter((f) => f.status === "played").map((f) => String(f.id)));
  const stats = new Map<string, Totals>();
  const of = (id: string) => {
    let s = stats.get(id);
    if (!s) stats.set(id, (s = { played: 0, goals: 0, assists: 0, mvps: 0, yellows: 0, reds: 0 }));
    return s;
  };
  for (const l of lineups) if (played.has(String(l.fixtureId))) of(String(l.memberId)).played++;
  for (const e of events) {
    if (!played.has(String(e.fixtureId))) continue;
    const m = String(e.memberId);
    switch (e.kind) {
      case "goal":
        of(m).goals++;
        if (e.assistMemberId) of(String(e.assistMemberId)).assists++;
        break;
      case "mvp":
        of(m).mvps++;
        break;
      case "yellow":
        of(m).yellows++;
        break;
      case "red":
        of(m).reds++;
        break;
    }
  }

  const { results: existing } = await db
    .prepare("SELECT member_id FROM member_stats WHERE club_id = ? AND period_id = ?")
    .bind(club.id, club.id)
    .all<{ member_id: string }>();
  const statements: D1PreparedStatement[] = [];
  for (const [memberId, s] of stats) {
    if (s.played === 0 && s.goals === 0 && s.assists === 0) continue;
    statements.push(
      db
        .prepare(
          `INSERT INTO member_stats (club_id, period_id, member_id, played, goals, assists, mvps, yellows, reds, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (club_id, period_id, member_id) DO UPDATE SET
             played = excluded.played, goals = excluded.goals, assists = excluded.assists, mvps = excluded.mvps,
             yellows = excluded.yellows, reds = excluded.reds, updated_at = excluded.updated_at
           WHERE (played, goals, assists, mvps, yellows, reds)
              IS NOT (excluded.played, excluded.goals, excluded.assists, excluded.mvps, excluded.yellows, excluded.reds)`,
        )
        .bind(club.id, club.id, memberId, s.played, s.goals, s.assists, s.mvps, s.yellows, s.reds, at),
    );
  }
  const kept = new Set([...stats.entries()].filter(([, s]) => s.played || s.goals || s.assists).map(([m]) => m));
  for (const e of existing) {
    if (!kept.has(e.member_id)) {
      statements.push(
        db.prepare("DELETE FROM member_stats WHERE club_id = ? AND period_id = ? AND member_id = ?").bind(club.id, club.id, e.member_id),
      );
    }
  }
  // Terminado: se congela (una vez). Abierto o reabierto: sigue al de ahora.
  statements.push(
    tournament?.status === "finished"
      ? db
          .prepare(
            `INSERT INTO period_tiers (club_id, period_id, tier, score, frozen_at) VALUES (?, ?, ?, 0, ?)
             ON CONFLICT (club_id, period_id) DO UPDATE SET tier = excluded.tier, frozen_at = excluded.frozen_at
             WHERE period_tiers.frozen_at IS NULL`,
          )
          .bind(club.id, club.id, tier, at)
      : db
          .prepare(
            `INSERT INTO period_tiers (club_id, period_id, tier, score, frozen_at) VALUES (?, ?, ?, 0, NULL)
             ON CONFLICT (club_id, period_id) DO UPDATE SET tier = excluded.tier, frozen_at = NULL
             WHERE (period_tiers.tier, period_tiers.frozen_at) IS NOT (excluded.tier, NULL)`,
          )
          .bind(club.id, club.id, tier),
  );
  const lastPlayed = fixtures
    .filter((f) => f.status === "played" && f.startsAt)
    .map((f) => String(f.startsAt))
    .sort()
    .pop();
  statements.push(
    db
      .prepare(
        `INSERT INTO club_metrics (club_id, computed_through, computed_at, tier, score, signals, play_days, active_players, last_played_at)
         VALUES (?, ?, ?, ?, 0, ?, '[]', ?, ?)
         ON CONFLICT (club_id) DO UPDATE SET computed_through = excluded.computed_through, computed_at = excluded.computed_at,
           tier = excluded.tier, signals = excluded.signals, active_players = excluded.active_players,
           last_played_at = excluded.last_played_at`,
      )
      .bind(
        club.id,
        last!.id,
        at,
        tier,
        JSON.stringify({ tournament: true, approvedTeams: approved, hostTier: host?.tier ?? null }),
        new Set(lineups.map((l) => String(l.memberId))).size,
        lastPlayed ?? null,
      ),
  );
  await db.batch(statements);
}
