import { z } from "zod";

/** Al registrarse: 3–20 caracteres `a-z 0-9 _ .`, sin distinguir mayúsculas ni espacios alrededor. */
export const newUsername = z
  .string()
  .trim()
  .toLowerCase()
  .regex(/^[a-z0-9_.]{3,20}$/, {
    error: "Entre 3 y 20 caracteres: letras sin tildes, números, punto o guion bajo",
  });

/** Al entrar se normaliza igual, pero sin validar el formato: uno mal escrito solo no coincide. */
export const existingUsername = z.string().trim().toLowerCase().min(1).max(40);

export const newPassword = z
  .string()
  .min(8, { error: "Mínimo 8 caracteres" })
  .max(200, { error: "Máximo 200 caracteres" });

const anyPassword = z.string().min(1).max(200);
const deviceLabel = z.string().trim().max(60).optional();

export const registerSchema = z.object({
  username: newUsername,
  password: newPassword,
  displayName: z.string().trim().min(1, { error: "Escribe tu nombre" }).max(40),
  deviceLabel,
});

export const loginSchema = z.object({
  username: existingUsername,
  password: anyPassword,
  deviceLabel,
});

export const recoverSchema = z.object({
  username: existingUsername,
  code: z.string().min(1).max(40),
  newPassword,
  deviceLabel,
});

export const changePasswordSchema = z.object({
  currentPassword: anyPassword,
  newPassword,
});

export const confirmPasswordSchema = z.object({ password: anyPassword });
