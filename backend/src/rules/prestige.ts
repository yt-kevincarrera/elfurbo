/**
 * Prestigio de un servidor (spec 2.0 §4): señales que cuestan falsear, una puntuación de 0 a 100 y
 * un nivel. Sin I/O: el job de estadísticas lee los datos y guarda el resultado.
 */
import type { PlayedMatchday } from "./stats";

export type Tier = "official" | "verified" | "established" | "casual" | "new";

/** De más a menos prestigio (para ordenar). */
export const TIER_RANK: Record<Tier, number> = { official: 4, verified: 3, established: 2, casual: 1, new: 0 };

/** Cuánto pesa cada nivel en el Índice Furbo. */
export const TIER_WEIGHT: Record<Tier, number> = { official: 1, verified: 0.8, established: 0.5, casual: 0.25, new: 0.25 };

export type Signals = {
  /** Días desde la primera jornada jugada. */
  ageDays: number;
  /** Jornadas jugadas en total. */
  totalPlayed: number;
  /** Jornadas jugadas en los últimos 90 días. */
  matchdays90: number;
  /** Jugadores por jornada, de promedio, en 90 días. */
  avgPlayers: number;
  /** Los distintos que jugaron en 90 días. */
  players90: number;
  confirmMode: boolean;
  confirmationsNeeded: number;
  /** De los reportes que cuentan en 90 días, los que puso o decidió el staff. */
  staffShare: number;
  /** De las presencias en 90 días, las comprobadas con el código de la jornada. */
  checkinShare: number;
  /** De los que jugaron en 90 días, los que tienen cuenta. */
  accountsShare: number;
  /** De los que jugaron en 90 días con cuenta, los que están activos en otro servidor. */
  networkShare: number;
  /** De los reportes en 90 días, los rechazados. */
  rejectedShare: number;
  /** Goles que cuentan por presencia, en 90 días. */
  goalsPerPresence: number;
};

const DAY_MS = 24 * 60 * 60 * 1000;

export type SignalInput = {
  matchdays: PlayedMatchday[];
  now: Date;
  confirmMode: boolean;
  confirmationsNeeded: number;
  /** Miembros con cuenta (id de miembro → id de usuario). */
  accounts: Map<string, string>;
  /** Usuarios activos en otro servidor activo. */
  elsewhere: Set<string>;
  /** Presencias comprobadas con código, por `jornada:miembro`. */
  checkins?: Set<string>;
};

/** Los que jugaron en los últimos 90 días (para preguntar después si están en otros servidores). */
export function recentPlayers(matchdays: PlayedMatchday[], now: Date) {
  const since = now.getTime() - 90 * DAY_MS;
  const players = new Set<string>();
  for (const md of matchdays) {
    if (Date.parse(md.startsAt) >= since) for (const p of md.players) players.add(p);
  }
  return players;
}

export function clubSignals(input: SignalInput): Signals {
  const { now } = input;
  const withPlayers = input.matchdays.filter((md) => md.players.size > 0);
  const since = now.getTime() - 90 * DAY_MS;
  const recent = withPlayers.filter((md) => Date.parse(md.startsAt) >= since);
  const first = withPlayers[0];
  const players = recentPlayers(recent, now);
  let presences = 0;
  let checkins = 0;
  let counted = 0;
  let byStaff = 0;
  let reports = 0;
  let rejected = 0;
  let goals = 0;
  for (const md of recent) {
    presences += md.players.size;
    for (const p of md.players) if (input.checkins?.has(`${md.id}:${p}`)) checkins++;
    for (const r of md.reports) {
      reports++;
      if (r.decision === "rejected") rejected++;
      if (!r.counts) continue;
      counted++;
      goals += r.goals;
      if (r.decision === "confirmed") byStaff++;
    }
  }
  const withAccount = [...players].filter((p) => input.accounts.has(p));
  const share = (n: number, of: number) => (of === 0 ? 0 : n / of);
  return {
    ageDays: first ? Math.max(0, Math.floor((now.getTime() - Date.parse(first.startsAt)) / DAY_MS)) : 0,
    totalPlayed: withPlayers.length,
    matchdays90: recent.length,
    avgPlayers: share(presences, recent.length),
    players90: players.size,
    confirmMode: input.confirmMode,
    confirmationsNeeded: input.confirmationsNeeded,
    staffShare: share(byStaff, counted),
    checkinShare: share(checkins, presences),
    accountsShare: share(withAccount.length, players.size),
    networkShare: share(withAccount.filter((p) => input.elsewhere.has(input.accounts.get(p)!)).length, withAccount.length),
    rejectedShare: share(rejected, reports),
    goalsPerPresence: share(goals, presences),
  };
}

export type ScorePart = { key: string; points: number; max: number };

const cap = (x: number) => Math.min(Math.max(x, 0), 1);

/** La puntuación (0–100) por partes, con las penalizaciones como partes negativas. */
export function scoreParts(s: Signals): ScorePart[] {
  const validation = s.confirmMode ? 10 + (s.confirmationsNeeded >= 2 ? 5 : 0) + 5 * s.staffShare + 5 * s.checkinShare : 0;
  const parts: ScorePart[] = [
    { key: "age", points: 15 * cap(s.ageDays / 180), max: 15 },
    { key: "activity", points: 15 * cap(s.matchdays90 / 12), max: 15 },
    { key: "size", points: 15 * cap(s.avgPlayers / 10), max: 15 },
    { key: "validation", points: validation, max: 25 },
    { key: "accounts", points: 15 * cap(s.accountsShare), max: 15 },
    { key: "network", points: 15 * cap(s.networkShare / 0.3), max: 15 },
  ];
  if (s.rejectedShare > 0.15) parts.push({ key: "rejected", points: -10, max: 0 });
  if (s.goalsPerPresence > 3) parts.push({ key: "goals", points: -15, max: 0 });
  else if (s.goalsPerPresence > 2) parts.push({ key: "goals", points: -5, max: 0 });
  return parts;
}

export function score(s: Signals) {
  const total = scoreParts(s).reduce((sum, p) => sum + p.points, 0);
  return Math.round(Math.min(Math.max(total, 0), 100));
}

/** El nivel. `trust` no pasa de Establecido; un servidor nuevo es Nuevo aunque puntúe alto. */
export function tierFor(s: Signals, official: boolean): Tier {
  if (official) return "official";
  if (s.ageDays < 30 || s.totalPlayed < 4) return "new";
  const points = score(s);
  if (points >= 70 && s.confirmMode) return "verified";
  if (points >= 40) return "established";
  return "casual";
}

const pct = (x: number) => `${Math.round(x * 100)} %`;
const one = (x: number) => (Math.round(x * 10) / 10).toLocaleString("es");

/**
 * Para los ajustes del dueño: cada parte con lo que suma y, si no está completa, qué hacer para
 * sumar más. En tono de la app (docs/tono.md).
 */
export function prestigeReport(s: Signals, official: boolean) {
  const tier = tierFor(s, official);
  const hints: Record<string, string | null> = {
    age:
      s.ageDays >= 180
        ? null
        : `Llevan ${s.ageDays} ${s.ageDays === 1 ? "día" : "días"} jugando: la antigüedad cuenta completa a los 6 meses.`,
    activity:
      s.matchdays90 >= 12 ? null : `${s.matchdays90} jornadas en los últimos 90 días: cuenta completa con 12 (una por semana).`,
    size: s.avgPlayers >= 10 ? null : `${one(s.avgPlayers)} jugadores por jornada de promedio: cuenta completa con 10.`,
    validation: !s.confirmMode
      ? 'Con "Confiando" no se pasa de Establecido: usa "Con confirmación".'
      : s.confirmationsNeeded < 2
        ? "Pide 2 confirmaciones o más para cada reporte."
        : s.staffShare < 0.5
          ? "Que el staff confirme o ponga más reportes."
          : null,
    accounts:
      s.accountsShare >= 0.95
        ? null
        : `${pct(s.accountsShare)} de los que juegan tienen cuenta: que los sin cuenta reclamen su perfil.`,
    network: s.networkShare >= 0.3 ? null : `${pct(s.networkShare)} juega también en otros servidores: cuenta completa con el 30 %.`,
    rejected: `Muchos reportes rechazados (${pct(s.rejectedShare)}).`,
    goals: `Promedio de goles muy alto: ${one(s.goalsPerPresence)} por jugador y jornada.`,
  };
  const parts = scoreParts(s).map((p) => ({
    key: p.key,
    points: Math.round(p.points * 10) / 10,
    max: p.max,
    hint: hints[p.key] ?? null,
  }));
  const newReason =
    tier === "new" ? `Un servidor es Nuevo hasta llevar 30 días y 4 jornadas jugadas (lleva ${s.totalPlayed}).` : null;
  return { tier, score: score(s), parts, newReason };
}
