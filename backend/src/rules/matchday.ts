/**
 * Reglas puras de una jornada (spec §5 y la spec de jornadas del 2026-09-14). Sin I/O: las usa el
 * backend al aplicar comandos, y los mismos casos de `shared-fixtures/matchday-rules.json` los
 * ejecuta la app en Dart para responder igual sin conexión.
 */

export type MatchdayStatus = "scheduled" | "cancelled" | "closed" | "reopened";

export type MatchdayTimes = {
  startsAt: string;
  durationMinutes: number;
  status: MatchdayStatus;
  seasonClosed: boolean;
};

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;

export function endsAt(md: MatchdayTimes) {
  return new Date(Date.parse(md.startsAt) + md.durationMinutes * MINUTE_MS);
}

/** Ya terminó: se pueden cargar goles, confirmar y votar. Una cancelada nunca "se jugó". */
export function isPlayed(md: MatchdayTimes, at: Date) {
  return md.status !== "cancelled" && at.getTime() >= endsAt(md).getTime();
}

/** Todavía no terminó: se puede marcar la intención (Voy / Quizás / No voy). */
export function acceptsIntent(md: MatchdayTimes, at: Date) {
  return md.status !== "cancelled" && at.getTime() < endsAt(md).getTime();
}

/**
 * No acepta cambios: temporada cerrada, cancelada o cerrada a mano; o pasaron `closeAfterHours`
 * desde el inicio, salvo que la hayan reabierto (entonces solo se cierra a mano).
 */
export function isClosed(md: MatchdayTimes, at: Date, closeAfterHours: number) {
  if (md.seasonClosed || md.status === "cancelled" || md.status === "closed") return true;
  if (md.status === "reopened") return false;
  return at.getTime() >= Date.parse(md.startsAt) + closeAfterHours * HOUR_MS;
}

/** Fecha local (AAAA-MM-DD) de un instante en una zona horaria: para detectar jornadas del mismo día. */
export function localDay(at: string, timezone: string) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).format(
    new Date(at),
  );
}
