import { TIER_WEIGHT, type Tier } from "./prestige";

export type IndexPeriod = { tier: Tier; played: number; goals: number; assists: number; mvps: number };

/** Jornadas ponderadas que hacen falta para dar un Índice Furbo. */
export const INDEX_MIN_WEIGHTED_PLAYED = 5;

/**
 * El Índice Furbo (spec 2.0 §4): lo que aporta un jugador por jornada, pesando cada período por el
 * nivel con que se jugó. null si no hay bastante (menos de 5 jornadas ponderadas).
 */
export function furboIndex(periods: IndexPeriod[]) {
  let value = 0;
  let played = 0;
  for (const p of periods) {
    const w = TIER_WEIGHT[p.tier];
    value += w * (p.goals + 0.7 * p.assists + 1.5 * p.mvps);
    played += w * p.played;
  }
  return played < INDEX_MIN_WEIGHTED_PLAYED ? null : Math.round((value / played) * 100) / 100;
}
