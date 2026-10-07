import { env } from "cloudflare:workers";

const DAY = 24 * 60 * 60 * 1000;
export const daysAgo = (n: number, now = Date.now()) => new Date(now - n * DAY).toISOString();

/** Miembros con cuenta (ids de usuario inventados: `members.user_id` no apunta a `users`). */
export async function seedMembers(clubId: string, n: number, prefix = "p") {
  const at = new Date().toISOString();
  const ids = Array.from({ length: n }, (_, i) => `${clubId}-${prefix}${i}`);
  await env.DB.batch(
    ids.map((id) =>
      env.DB.prepare(
        "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, ?, 'player', ?, ?, ?)",
      ).bind(id, clubId, `u-${id}`, id, at, at),
    ),
  );
  return ids;
}

export async function activeSeason(clubId: string) {
  return (await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ? AND is_active = 1").bind(clubId).first<{ id: string }>())!.id;
}

type Played = { member: string; goals?: number; assists?: number; decision?: "confirmed" | "rejected" | null; report?: boolean };

/**
 * Una jornada jugada, directa en D1: quién jugó y, si se pide, su reporte (por defecto confirmado
 * por el staff). Devuelve su id.
 */
export async function seedMatchday(clubId: string, seasonId: string, startsAt: string, players: Played[], staff: string) {
  const id = crypto.randomUUID();
  const at = new Date().toISOString();
  const statements = [
    env.DB.prepare(
      "INSERT INTO matchdays (id, club_id, season_id, starts_at, duration_minutes, status, created_by, created_at, updated_at) VALUES (?, ?, ?, ?, 0, 'scheduled', ?, ?, ?)",
    ).bind(id, clubId, seasonId, startsAt, staff, at, at),
  ];
  for (const p of players) {
    statements.push(
      env.DB.prepare(
        "INSERT INTO attendance (id, club_id, matchday_id, member_id, intent, played, updated_at) VALUES (?, ?, ?, ?, 'yes', 1, ?)",
      ).bind(`${id}:${p.member}`, clubId, id, p.member, at),
    );
    if (p.report === false) continue;
    statements.push(
      env.DB.prepare(
        "INSERT INTO reports (id, club_id, matchday_id, member_id, goals, assists, loaded_by, decision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      ).bind(
        `${id}:${p.member}`,
        clubId,
        id,
        p.member,
        p.goals ?? 1,
        p.assists ?? 0,
        staff,
        p.decision === undefined ? "confirmed" : p.decision,
        at,
      ),
    );
  }
  await env.DB.batch(statements);
  return id;
}

/** Una jornada por semana durante `weeks` semanas hasta hoy, con todos los `players`. */
export async function seedWeekly(clubId: string, players: string[], weeks: number, staff: string, goals = 1) {
  const season = await activeSeason(clubId);
  for (let w = weeks; w >= 1; w--) {
    await seedMatchday(clubId, season, daysAgo(w * 7), players.map((member) => ({ member, goals })), staff);
  }
  return season;
}

export async function metrics(clubId: string) {
  return env.DB.prepare("SELECT * FROM club_metrics WHERE club_id = ?").bind(clubId).first<Record<string, unknown>>();
}

export async function memberStats(clubId: string) {
  const { results } = await env.DB.prepare("SELECT * FROM member_stats WHERE club_id = ? ORDER BY member_id")
    .bind(clubId)
    .all<Record<string, unknown>>();
  return results;
}
