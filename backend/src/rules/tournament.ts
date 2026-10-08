import { z } from "zod";

/** Las reglas de un torneo (spec 2.0 §7.1), con sus valores por defecto. */
export const rulesSchema = z
  .object({
    pointsWin: z.number().int().min(0).max(10),
    pointsDraw: z.number().int().min(0).max(10),
    pointsLoss: z.number().int().min(0).max(10),
    /** Vueltas de la liga o de los grupos. */
    legs: z.number().int().min(1).max(2),
    groups: z.number().int().min(1).max(8),
    advancePerGroup: z.number().int().min(1).max(4),
    thirdPlace: z.boolean(),
    tiebreakers: z
      .array(z.enum(["points", "goalDiff", "goalsFor", "headToHead", "fairPlay"]))
      .min(1)
      .max(5)
      .refine((t) => new Set(t).size === t.length, { error: "Sin repetir" }),
    yellowsForBan: z.number().int().min(0).max(10),
    redBanMatches: z.number().int().min(0).max(5),
    playersOnField: z.number().int().min(3).max(11),
    matchMinutes: z.number().int().min(10).max(120),
    knockoutTies: z.enum(["penalties"]),
  })
  .strict();

export type TournamentRules = z.infer<typeof rulesSchema>;

export const DEFAULT_RULES: TournamentRules = {
  pointsWin: 3,
  pointsDraw: 1,
  pointsLoss: 0,
  legs: 1,
  groups: 2,
  advancePerGroup: 2,
  thirdPlace: false,
  tiebreakers: ["points", "goalDiff", "goalsFor", "headToHead", "fairPlay"],
  yellowsForBan: 3,
  redBanMatches: 1,
  playersOnField: 7,
  matchMinutes: 50,
  knockoutTies: "penalties",
};

export const rulesOf = (raw: string): TournamentRules => ({ ...DEFAULT_RULES, ...(JSON.parse(raw) as Partial<TournamentRules>) });

export type TournamentFormat = "league" | "cup" | "groups_cup";
export type TournamentStatus = "draft" | "registration" | "in_progress" | "finished";

const ORDER: TournamentStatus[] = ["draft", "registration", "in_progress", "finished"];

/** El estado solo avanza (terminar y reabrir van por sus propios comandos). */
export function canAdvance(from: TournamentStatus, to: TournamentStatus) {
  return to !== "finished" && ORDER.indexOf(to) > ORDER.indexOf(from);
}

/** Cualquiera (con cuenta) puede inscribir un equipo: inscripción abierta y antes del cierre. */
export const registrationOpen = (status: TournamentStatus, closesAt: string | null, now: Date) =>
  status === "registration" && (closesAt === null || now.toISOString() < closesAt);

/** Un capitán todavía arma su plantilla: el torneo no ha empezado. */
export const rostersOpen = (status: TournamentStatus) => status === "draft" || status === "registration";
