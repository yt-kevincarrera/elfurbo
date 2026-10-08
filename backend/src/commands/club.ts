import { z } from "zod";
import { canManageClub } from "../authz";
import { transferOwnership as transferStatements } from "../clubs/transfer";
import { errors } from "../http/errors";
import { PROVINCE_CODES } from "../rules/provinces";
import { upsert } from "../sync/changes";
import { command } from "../sync/command";

function isTimeZone(tz: string) {
  try {
    new Intl.DateTimeFormat("en", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/** Cambios parciales de los ajustes (spec §2). Lo que no venga se queda como está. */
export const updateSettings = command(
  z
    .object({
      matchdayCreators: z.enum(["members", "staff"]).optional(),
      reportValidation: z.enum(["confirm", "trust"]).optional(),
      confirmationsNeeded: z.number().int().min(1).max(5).optional(),
      closeAfterHours: z.number().int().min(24).max(168).optional(),
      timezone: z.string().min(1).max(64).refine(isTimeZone, { error: "Zona horaria no válida" }).optional(),
      shareStats: z.boolean().optional(),
      maxPlayers: z.number().int().min(0).max(60).optional(),
    })
    .strict(),
  async (ctx, p) => {
    if (!canManageClub(ctx.member.role)) throw errors.forbidden();
    const settings = { ...ctx.club.settings, ...p };
    return {
      statements: [
        ctx.db
          .prepare("UPDATE clubs SET settings = ?, updated_at = ? WHERE id = ?")
          .bind(JSON.stringify(settings), ctx.now.toISOString(), ctx.club.id),
      ],
      touched: [upsert("club", ctx.club.id)],
      audit: [{ action: "club.updateSettings", entity: "club", entityKey: ctx.club.id, summary: p }],
    };
  },
);

/** Texto opcional: vacío o solo espacios es "sin valor". */
const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max, { error: `Máximo ${max} caracteres` })
    .nullable()
    .transform((v) => (v ? v : null));

/** Nombre, descripción, provincia, ciudad y color del servidor (spec 2.0 §2). Solo el owner. */
export const updateProfile = command(
  z
    .object({
      name: z.string().trim().min(3, { error: "Mínimo 3 caracteres" }).max(40, { error: "Máximo 40 caracteres" }).optional(),
      description: z.string().trim().max(200, { error: "Máximo 200 caracteres" }).optional(),
      province: z.enum(PROVINCE_CODES).nullable().optional(),
      city: optionalText(40).optional(),
      color: z.number().int().min(0).max(7).optional(),
    })
    .strict()
    .refine((p) => Object.keys(p).length > 0, { error: "No hay nada que cambiar" }),
  async (ctx, p) => {
    if (!canManageClub(ctx.member.role)) throw errors.forbidden();
    const sets: string[] = [];
    const binds: unknown[] = [];
    const column = { name: "name", description: "description", province: "province", city: "city", color: "color" };
    for (const [k, v] of Object.entries(p)) {
      sets.push(`${column[k as keyof typeof column]} = ?`);
      binds.push(v);
    }
    return {
      statements: [
        ctx.db
          .prepare(`UPDATE clubs SET ${sets.join(", ")}, updated_at = ? WHERE id = ?`)
          .bind(...binds, ctx.now.toISOString(), ctx.club.id),
      ],
      touched: [upsert("club", ctx.club.id)],
      audit: [{ action: "club.updateProfile", entity: "club", entityKey: ctx.club.id, summary: p }],
    };
  },
);

/**
 * Privado (solo por invitación) o público (sale en el directorio). En uno público, `joinPolicy` dice
 * si entrar se pide o es al momento. Solo el owner, y no si el superadmin lo sacó del directorio.
 */
export const setVisibility = command(
  z
    .object({
      visibility: z.enum(["private", "public"]),
      joinPolicy: z.enum(["request", "open"]).optional(),
    })
    .strict(),
  async (ctx, p) => {
    if (!canManageClub(ctx.member.role)) throw errors.forbidden();
    if (p.visibility === "public" && ctx.club.delisted) throw errors.clubDelisted();
    const settings = p.joinPolicy ? { ...ctx.club.settings, joinPolicy: p.joinPolicy } : ctx.club.settings;
    return {
      statements: [
        ctx.db
          .prepare("UPDATE clubs SET visibility = ?, settings = ?, updated_at = ? WHERE id = ?")
          .bind(p.visibility, JSON.stringify(settings), ctx.now.toISOString(), ctx.club.id),
      ],
      touched: [upsert("club", ctx.club.id)],
      audit: [{ action: "club.setVisibility", entity: "club", entityKey: ctx.club.id, summary: p }],
    };
  },
);

/** El dueño pasa la propiedad a otro miembro con cuenta; él se queda como admin. */
export const transferOwnership = command(z.object({ memberId: z.string().min(1).max(64) }), async (ctx, p) => {
  if (!canManageClub(ctx.member.role)) throw errors.forbidden();
  const t = await transferStatements(ctx.db, ctx.club, p.memberId, ctx.now);
  return {
    statements: t.statements,
    touched: t.touched,
    audit: [
      {
        action: "club.transfer",
        entity: "club",
        entityKey: ctx.club.id,
        summary: { from: ctx.club.ownerUserId, to: t.target.userId },
      },
    ],
  };
});
