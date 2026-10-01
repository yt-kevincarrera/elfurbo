import type { z } from "zod";
import type { AuditEntry } from "../audit";
import type { PublicUser } from "../auth/users";
import type { ClubRecord, MemberRecord } from "../clubs/model";
import type { Touch } from "./changes";

/** Lo que un comando sabe al ejecutarse. `clientAt` ya viene acotado (ver `effectiveClientAt`). */
export type CommandContext = {
  db: D1Database;
  now: Date;
  clientAt: Date;
  user: PublicUser;
  club: ClubRecord;
  member: MemberRecord;
};

/**
 * Lo que produce un comando: sentencias que se aplican en un solo `batch`, las entidades que toca
 * (para `changes`) y, si hace falta, filas de auditoría. El motor añade el resto.
 */
export type Effect = {
  statements: D1PreparedStatement[];
  touched: Touch[];
  audit?: Omit<AuditEntry, "clubId" | "actorUserId">[];
};

/** Un tipo de comando: su esquema y lo que hace. El motor solo llama a `run` con un payload ya validado. */
export type CommandHandler = {
  schema: z.ZodType;
  run: (ctx: CommandContext, payload: never) => Promise<Effect>;
};

/** Define un handler con el payload tipado a partir de su esquema. */
export function command<S extends z.ZodType>(
  schema: S,
  run: (ctx: CommandContext, payload: z.output<S>) => Promise<Effect>,
) {
  return { schema, run } satisfies CommandHandler;
}

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * La hora del teléfono solo se cree si no está en el futuro y es de hace menos de 7 días (spec §5).
 * Así un reporte hecho a tiempo sin señal no se rechaza por subirse tarde, pero un reloj mal puesto
 * no sirve para saltarse plazos.
 */
export function effectiveClientAt(clientAt: Date, now: Date) {
  const t = clientAt.getTime();
  return t <= now.getTime() && now.getTime() - t < WEEK_MS ? clientAt : now;
}
