/**
 * Estadísticas de un servidor a partir de las filas del pull (spec 2.0 §3). Lo mismo que calcula la
 * app con `reportsFromCloud` + `StatsEngine` (lib/domain/): los dos lados pasan los casos de
 * `shared-fixtures/stats.json`. Sin I/O.
 */
import { isPlayed, type MatchdayStatus } from "./matchday";

type Row = Record<string, unknown>;

export type StatsRows = {
  matchday: Row[];
  attendance: Row[];
  report: Row[];
  confirmation: Row[];
  vote: Row[];
};

export type StatsSettings = { reportValidation: "confirm" | "trust"; confirmationsNeeded: number };

export type MemberStats = {
  played: number;
  goals: number;
  assists: number;
  mvps: number;
  hatTricks: number;
  pokers: number;
  completeMatches: number;
  bestDayGoals: number;
  bestStreak: number;
  /** Reportes en jornadas jugadas del período, y cuántos rechazó el staff. */
  reports: number;
  rejected: number;
};

/** Un reporte con lo que hace falta para la regla de "cuenta". */
export type CountedReport = {
  matchdayId: string;
  memberId: string;
  goals: number;
  assists: number;
  decision: "confirmed" | "rejected" | null;
  loadedBy: string | null;
  counts: boolean;
  pending: boolean;
};

const str = (v: unknown) => String(v);
const num = (v: unknown) => (typeof v === "number" ? v : Number(v ?? 0) || 0);

/**
 * La regla de "cuenta" (spec 1.0 §2): solo valen las confirmaciones de quienes jugaron; lo que
 * pone o decide el staff llega con decisión "confirmado"; confiando, todo cuenta salvo un rechazo.
 */
export function countReports(rows: Pick<StatsRows, "report" | "confirmation" | "attendance">, settings: StatsSettings) {
  const present = new Set(
    rows.attendance.filter((a) => a.played === true).map((a) => `${str(a.matchdayId)}:${str(a.memberId)}`),
  );
  const confirmations = new Map<string, number>();
  for (const c of rows.confirmation) {
    if (!present.has(`${str(c.matchdayId)}:${str(c.confirmerId)}`)) continue;
    const key = `${str(c.matchdayId)}:${str(c.memberId)}`;
    confirmations.set(key, (confirmations.get(key) ?? 0) + 1);
  }
  return rows.report.map((r): CountedReport => {
    const decision = (r.decision ?? null) as CountedReport["decision"];
    const key = `${str(r.matchdayId)}:${str(r.memberId)}`;
    const confirmed =
      decision === "confirmed" ||
      (decision === null &&
        (settings.reportValidation === "trust" || (confirmations.get(key) ?? 0) >= settings.confirmationsNeeded));
    return {
      matchdayId: str(r.matchdayId),
      memberId: str(r.memberId),
      goals: num(r.goals),
      assists: num(r.assists),
      decision,
      loadedBy: (r.loadedBy ?? null) as string | null,
      counts: confirmed,
      pending: !confirmed && decision === null,
    };
  });
}

/**
 * MVP de una jornada: el más votado; si hay empate, más goles confirmados del día y luego más
 * asistencias; si sigue igual, todos los empatados (ordenados).
 */
export function mvpWinners(votes: Row[], confirmed: Map<string, CountedReport>) {
  if (votes.length === 0) return [];
  const counts = new Map<string, number>();
  for (const v of votes) counts.set(str(v.votedFor), (counts.get(str(v.votedFor)) ?? 0) + 1);
  const max = Math.max(...counts.values());
  let tied = [...counts.entries()].filter(([, n]) => n === max).map(([id]) => id);
  if (tied.length === 1) return tied;
  const goals = (id: string) => confirmed.get(id)?.goals ?? 0;
  const assists = (id: string) => confirmed.get(id)?.assists ?? 0;
  const bestGoals = Math.max(...tied.map(goals));
  tied = tied.filter((id) => goals(id) === bestGoals);
  if (tied.length > 1) {
    const bestAssists = Math.max(...tied.map(assists));
    tied = tied.filter((id) => assists(id) === bestAssists);
  }
  return tied.sort();
}

export type PlayedMatchday = { id: string; startsAt: string; players: Set<string>; reports: CountedReport[]; mvps: string[] };

/**
 * Las jornadas ya jugadas del período (`seasonId` null = todas), en orden, con quién jugó (presencia
 * real o reporte que cuenta), sus reportes y su MVP.
 */
export function playedMatchdays(rows: StatsRows, settings: StatsSettings, seasonId: string | null, now: Date) {
  const matchdays = rows.matchday
    .filter((m) => seasonId === null || str(m.seasonId) === seasonId)
    .filter((m) =>
      isPlayed(
        { startsAt: str(m.startsAt), durationMinutes: num(m.durationMinutes), status: m.status as MatchdayStatus, seasonClosed: false },
        now,
      ),
    )
    // A la misma hora, por id (como la app): el orden decide las rachas.
    .sort((a, b) => Date.parse(str(a.startsAt)) - Date.parse(str(b.startsAt)) || (str(a.id) < str(b.id) ? -1 : str(a.id) > str(b.id) ? 1 : 0));
  const ids = new Set(matchdays.map((m) => str(m.id)));
  const reports = countReports(rows, settings).filter((r) => ids.has(r.matchdayId));
  const byMatchday = new Map<string, PlayedMatchday>();
  for (const m of matchdays) {
    byMatchday.set(str(m.id), { id: str(m.id), startsAt: str(m.startsAt), players: new Set(), reports: [], mvps: [] });
  }
  for (const a of rows.attendance) {
    if (a.played === true) byMatchday.get(str(a.matchdayId))?.players.add(str(a.memberId));
  }
  for (const r of reports) {
    const md = byMatchday.get(r.matchdayId)!;
    md.reports.push(r);
    if (r.counts) md.players.add(r.memberId);
  }
  const votes = new Map<string, Row[]>();
  for (const v of rows.vote) {
    if (!ids.has(str(v.matchdayId))) continue;
    votes.set(str(v.matchdayId), [...(votes.get(str(v.matchdayId)) ?? []), v]);
  }
  for (const md of byMatchday.values()) {
    const confirmed = new Map(md.reports.filter((r) => r.counts).map((r) => [r.memberId, r]));
    md.mvps = mvpWinners(votes.get(md.id) ?? [], confirmed);
  }
  return matchdays.map((m) => byMatchday.get(str(m.id))!);
}

const empty = (): MemberStats => ({
  played: 0,
  goals: 0,
  assists: 0,
  mvps: 0,
  hatTricks: 0,
  pokers: 0,
  completeMatches: 0,
  bestDayGoals: 0,
  bestStreak: 0,
  reports: 0,
  rejected: 0,
});

/** Los totales por miembro de un período, como `StatsEngine` en la app. */
export function computeStats(rows: StatsRows, settings: StatsSettings, seasonId: string | null, now: Date) {
  return statsOf(playedMatchdays(rows, settings, seasonId, now));
}

export function statsOf(matchdays: PlayedMatchday[]) {
  const stats = new Map<string, MemberStats>();
  const of = (id: string) => {
    let s = stats.get(id);
    if (!s) stats.set(id, (s = empty()));
    return s;
  };
  const streak = new Map<string, number>();
  for (const md of matchdays) {
    for (const id of md.players) {
      const s = of(id);
      s.played++;
      const n = (streak.get(id) ?? 0) + 1;
      streak.set(id, n);
      s.bestStreak = Math.max(s.bestStreak, n);
    }
    for (const id of streak.keys()) if (!md.players.has(id)) streak.set(id, 0);
    for (const r of md.reports) {
      const s = of(r.memberId);
      s.reports++;
      if (r.decision === "rejected") s.rejected++;
      if (!r.counts) continue;
      s.goals += r.goals;
      s.assists += r.assists;
      if (r.goals >= 3) s.hatTricks++;
      if (r.goals >= 4) s.pokers++;
      if (r.goals > 0 && r.assists > 0) s.completeMatches++;
      s.bestDayGoals = Math.max(s.bestDayGoals, r.goals);
    }
    for (const id of md.mvps) of(id).mvps++;
  }
  return stats;
}
