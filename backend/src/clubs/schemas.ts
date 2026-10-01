import { z } from "zod";

export const clubRequestSchema = z.object({
  name: z.string().trim().min(3, { error: "Mínimo 3 caracteres" }).max(40, { error: "Máximo 40 caracteres" }),
  description: z.string().trim().max(200).default(""),
  requestNote: z.string().trim().max(300).default(""),
});

export const createInviteSchema = z.object({
  role: z.enum(["player", "scorer", "admin"]).default("player"),
  maxUses: z.number().int().min(1).max(100).default(1),
  expiresInDays: z.number().int().min(1).max(30).default(7),
  /** Para que un jugador sin cuenta reclame su perfil. Fuerza `role = player` y `maxUses = 1`. */
  targetMemberId: z.string().min(1).max(64).optional(),
});
