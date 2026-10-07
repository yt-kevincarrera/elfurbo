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
  invalidInput: (details?: unknown) => new ApiError(400, "invalid_input", "Hay algo en los datos que no cuadra", details),
  payloadTooLarge: () => new ApiError(413, "payload_too_large", "Es demasiado para enviarlo de una vez"),
  unauthorized: () => new ApiError(401, "unauthorized", "Entra con tu cuenta para seguir"),
  sessionExpired: () => new ApiError(401, "session_expired", "Tu sesión caducó. Vuelve a entrar"),
  invalidCredentials: () => new ApiError(401, "invalid_credentials", "El usuario o la contraseña no coinciden"),
  invalidRecoveryCode: () =>
    new ApiError(400, "invalid_recovery_code", "El código no es válido o ya caducó"),
  accountSuspended: () => new ApiError(403, "account_suspended", "Tu cuenta está suspendida"),
  usernameTaken: () => new ApiError(409, "username_taken", "Ese nombre de usuario ya existe"),
  tooManyAttempts: (retryAfterSeconds: number) =>
    new ApiError(429, "too_many_attempts", "Muchos intentos seguidos. Espérate unos minutos", {
      retryAfterSeconds,
    }),
  notFound: () => new ApiError(404, "not_found", "Eso no existe o ya no está"),
  forbidden: () => new ApiError(403, "forbidden", "Eso no lo puedes hacer tú"),
  clubSuspended: () =>
    new ApiError(403, "club_suspended", "Este servidor está suspendido: solo se puede consultar"),
  invalidState: (message: string) => new ApiError(409, "invalid_state", message),
  tooManyClubs: () =>
    new ApiError(409, "too_many_clubs", "Ya tienes 3 servidores activos o pendientes de aprobación"),
  alreadyMember: () => new ApiError(409, "already_member", "Ya tienes un perfil en este servidor"),
  bannedFromClub: () => new ApiError(403, "banned_from_club", "No puedes volver a entrar en este servidor"),
  inviteInvalid: () =>
    new ApiError(404, "invite_invalid", "La invitación no existe, caducó o ya se usó"),
  recoveryNeedsSuperadmin: () =>
    new ApiError(
      403,
      "recovery_needs_superadmin",
      "Esta persona administra la app u otro servidor: el código se lo tiene que dar el superadmin",
    ),
  matchdayClosed: () => new ApiError(409, "matchday_closed", "La jornada está cerrada: ya no acepta cambios"),
  matchdayNotPlayed: () => new ApiError(409, "matchday_not_played", "La jornada todavía no se ha jugado"),
  matchdayAlreadyPlayed: () =>
    new ApiError(409, "matchday_already_played", "La jornada ya se jugó: marca si jugaste o no"),
  notPresent: () => new ApiError(409, "not_present", "Solo pueden hacer esto los que jugaron esa jornada"),
  reportRejected: () =>
    new ApiError(409, "report_rejected", "El admin rechazó este reporte: ya no se puede cambiar"),
  noActiveSeason: () => new ApiError(409, "no_active_season", "No hay temporada activa: crea o activa una"),
  seasonClosed: () => new ApiError(409, "season_closed", "Esa temporada está cerrada"),
  seasonHasMatchdays: () =>
    new ApiError(409, "season_has_matchdays", "La temporada tiene jornadas: muévelas o bórralas antes"),
  ownerCannotLeave: () =>
    new ApiError(409, "owner_cannot_leave", "Eres el dueño: transfiere el servidor antes de salir"),
  appOutdated: () =>
    new ApiError(426, "app_outdated", "Actualiza la app para seguir sincronizando"),
  clubDelisted: () =>
    new ApiError(
      409,
      "club_delisted",
      "El superadmin sacó este servidor del directorio. Habla con él para volver a ponerlo",
    ),
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
    { error: { code: "internal", message: "Algo se trabó en el servidor. Dale otra vez", details: null } },
    500,
  );
}
