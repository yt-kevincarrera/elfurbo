import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";

/** Error de la API con código estable (para la app) y mensaje en español (para el usuario). */
export class ApiError extends Error {
  constructor(
    readonly status: ContentfulStatusCode,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

export const errors = {
  invalidInput: (details?: unknown) => new ApiError(400, "invalid_input", "Datos no válidos", details),
  payloadTooLarge: () => new ApiError(413, "payload_too_large", "La petición es demasiado grande"),
  unauthorized: () => new ApiError(401, "unauthorized", "Inicia sesión para continuar"),
  sessionExpired: () => new ApiError(401, "session_expired", "Tu sesión caducó. Vuelve a entrar"),
  invalidCredentials: () => new ApiError(401, "invalid_credentials", "Usuario o contraseña incorrectos"),
  invalidRecoveryCode: () =>
    new ApiError(400, "invalid_recovery_code", "El código no es válido o ya caducó"),
  accountSuspended: () => new ApiError(403, "account_suspended", "Tu cuenta está suspendida"),
  usernameTaken: () => new ApiError(409, "username_taken", "Ese nombre de usuario ya existe"),
  tooManyAttempts: (retryAfterSeconds: number) =>
    new ApiError(429, "too_many_attempts", "Demasiados intentos. Espera unos minutos", {
      retryAfterSeconds,
    }),
  notFound: () => new ApiError(404, "not_found", "No encontrado"),
  forbidden: () => new ApiError(403, "forbidden", "No tienes permiso para hacer esto"),
  clubSuspended: () =>
    new ApiError(403, "club_suspended", "Este servidor está suspendido: solo se puede consultar"),
  invalidState: (message: string) => new ApiError(409, "invalid_state", message),
  tooManyClubs: () =>
    new ApiError(409, "too_many_clubs", "Ya tienes 3 servidores activos o pendientes de aprobación"),
  alreadyMember: () => new ApiError(409, "already_member", "Ya tienes un perfil en este servidor"),
  bannedFromClub: () => new ApiError(403, "banned_from_club", "No puedes volver a entrar en este servidor"),
  inviteInvalid: () =>
    new ApiError(404, "invite_invalid", "La invitación no existe, caducó o ya se usó"),
  ownerMustTransfer: () =>
    new ApiError(409, "owner_must_transfer", "Eres dueño de un servidor: transfiérelo antes de borrar tu cuenta"),
};

export function errorResponse(c: Context, err: ApiError) {
  if (err.code === "too_many_attempts") {
    const { retryAfterSeconds } = err.details as { retryAfterSeconds: number };
    c.header("Retry-After", String(retryAfterSeconds));
  }
  return c.json(
    { error: { code: err.code, message: err.message, details: err.details ?? null } },
    err.status,
  );
}

export function handleError(err: Error, c: Context) {
  if (err instanceof ApiError) return errorResponse(c, err);
  console.error(err);
  return c.json(
    { error: { code: "internal", message: "Error interno. Inténtalo de nuevo", details: null } },
    500,
  );
}
