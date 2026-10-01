import { z } from "zod";
import { canManageClub } from "../authz";
import { transferOwnership as transferStatements } from "../clubs/transfer";
import { errors } from "../http/errors";
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
