import { z } from "zod";

export const clubRequestSchema = z.object({
  name: z.string().trim().min(3, { error: "Mínimo 3 caracteres" }).max(40, { error: "Máximo 40 caracteres" }),
  description: z.string().trim().max(200).default(""),
  requestNote: z.string().trim().max(300).default(""),
});
