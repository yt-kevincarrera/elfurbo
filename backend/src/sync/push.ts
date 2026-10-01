import { z } from "zod";
import { auditStatement } from "../audit";
import type { PublicUser } from "../auth/users";
import { assertWritable, requireMembership } from "../clubs/model";
import { ApiError, errors } from "../http/errors";
import { changeStatement } from "./changes";
import { effectiveClientAt } from "./command";
import { HANDLERS } from "./handlers";

export const commandSchema = z.object({
  id: z.uuid(),
  clubId: z.string().min(1).max(64),
  type: z.string().min(1).max(64),
  payload: z.unknown(),
  clientAt: z.iso.datetime({ offset: true }),
});

export const pushSchema = z.object({ commands: z.array(commandSchema).min(1).max(200) });

export type Command = z.infer<typeof commandSchema>;

type Outcome = { status: "applied" } | { status: "rejected"; code: string; message: string; details: unknown };

export type CommandResult =
  | ({ id: string } & Outcome)
  | { id: string; status: "duplicate"; original: Outcome }
  | { id: string; status: "error"; code: "internal"; message: string };

/**
 * Aplica los comandos en orden. Cada uno va en su propio `batch` (atómico) junto con sus filas de
 * `changes`, su auditoría y su fila en `applied_commands`. Uno rechazado no frena a los siguientes.
 * Los rechazos también se guardan, para que un reintento reciba la misma respuesta.
 */
export async function applyCommands(db: D1Database, user: PublicUser, commands: Command[], now: Date) {
  const results: CommandResult[] = [];
  for (const cmd of commands) results.push(await applyOne(db, user, cmd, now));
  return results;
}

async function applyOne(db: D1Database, user: PublicUser, cmd: Command, now: Date): Promise<CommandResult> {
  const stored = await db
    .prepare("SELECT user_id, status, result FROM applied_commands WHERE id = ?")
    .bind(cmd.id)
    .first<{ user_id: string; status: string; result: string }>();
  if (stored) {
    if (stored.user_id !== user.id) {
      return { id: cmd.id, status: "rejected", code: "invalid_input", message: "Ese id de comando ya se usó", details: null };
    }
    return { id: cmd.id, status: "duplicate", original: JSON.parse(stored.result) as Outcome };
  }

  let outcome: Outcome;
  try {
    const handler = HANDLERS[cmd.type];
    if (!handler) throw new ApiError(400, "unknown_command", "La app es más nueva que el servidor: actualízala");
    const { club, member } = await requireMembership(db, cmd.clubId, user.id);
    assertWritable(club);
    const parsed = handler.schema.safeParse(cmd.payload);
    if (!parsed.success) throw errors.invalidInput(z.flattenError(parsed.error).fieldErrors);

    const ctx = { db, now, clientAt: effectiveClientAt(new Date(cmd.clientAt), now), user, club, member };
    const effect = await handler.run(ctx, parsed.data as never);
    outcome = { status: "applied" };
    await db.batch([
      ...effect.statements,
      ...effect.touched.map((t) => changeStatement(db, club.id, t, now)),
      ...(effect.audit ?? []).map((a) => auditStatement(db, { ...a, clubId: club.id, actorUserId: user.id }, now)),
      recordStatement(db, user.id, cmd, outcome, now),
    ]);
    return { id: cmd.id, ...outcome };
  } catch (e) {
    if (e instanceof ApiError) {
      outcome = { status: "rejected", code: e.code, message: e.message, details: e.details ?? null };
    } else if (/UNIQUE constraint failed|CHECK constraint failed|FOREIGN KEY constraint failed/.test(String(e))) {
      outcome = { status: "rejected", code: "conflict", message: "Ese cambio choca con otro que ya está guardado", details: null };
    } else {
      // Fallo inesperado: no se guarda, para que la app lo reintente más tarde.
      console.error(e);
      return { id: cmd.id, status: "error", code: "internal", message: "Error interno. Se reintentará" };
    }
    await recordStatement(db, user.id, cmd, outcome, now).run();
    return { id: cmd.id, ...outcome };
  }
}

function recordStatement(db: D1Database, userId: string, cmd: Command, outcome: Outcome, now: Date) {
  return db
    .prepare(
      "INSERT INTO applied_commands (id, user_id, club_id, type, status, result, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(cmd.id, userId, cmd.clubId, cmd.type, outcome.status, JSON.stringify(outcome), now.toISOString());
}
