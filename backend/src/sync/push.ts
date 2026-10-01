import { z } from "zod";
import { auditStatement } from "../audit";
import type { PublicUser } from "../auth/users";
import { assertWritable, requireMembership, type ClubRecord, type MemberRecord } from "../clubs/model";
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
  | { id: string; status: "deferred"; code: "budget" | "unknown_command"; message: string }
  | { id: string; status: "error"; code: "internal"; message: string };

/**
 * Consultas a D1 que puede gastar el motor en una petición. El límite medido en el plan gratuito es
 * 1000 por invocación (la 1001 falla); se deja margen para la sesión y imprevistos.
 */
export const QUERY_BUDGET = 900;
/** Lo que puede costar un comando como mucho: membresía (2, si no está en caché), lecturas del handler (≤3), batch y una relectura si choca (2). */
const MEMBERSHIP_QUERIES = 2;
const MAX_HANDLER_READS = 3;
const MAX_WRITE_QUERIES = 2;
/**
 * Tiempo que dedica una petición a aplicar comandos antes de aplazar el resto. Con la conexión de
 * Cuba, una respuesta corta es una respuesta que llega: mejor varias tandas de pocos segundos.
 */
export const TIME_BUDGET_MS = 8000;
/** D1 admite como mucho 100 parámetros por sentencia. */
const CHUNK = 90;

type Stored = { user_id: string; result: string };
type Membership = { club: ClubRecord; member: MemberRecord } | ApiError;

/**
 * Aplica los comandos en orden. Cada uno va en su propio `batch` (atómico) junto con sus filas de
 * `changes`, su auditoría y su fila en `applied_commands`. Uno rechazado no frena a los siguientes.
 *
 * Solo se guardan los resultados que dependen del estado del servidor (aplicado, o rechazado por el
 * handler): así un reintento recibe la misma respuesta, pero nadie puede gastar escrituras mandando
 * comandos a servidores ajenos o mal formados. Si no queda presupuesto de consultas, el resto vuelve
 * `deferred` (en orden y sin guardarse) y la app lo reenvía.
 */
export async function applyCommands(
  db: D1Database,
  user: PublicUser,
  commands: Command[],
  now: Date,
  { queryBudget = QUERY_BUDGET, timeBudgetMs = TIME_BUDGET_MS }: { queryBudget?: number; timeBudgetMs?: number } = {},
): Promise<CommandResult[]> {
  const deadline = Date.now() + timeBudgetMs;
  let left = queryBudget;
  const stored = new Map<string, Stored>();
  for (let i = 0; i < commands.length; i += CHUNK) {
    const ids = commands.slice(i, i + CHUNK).map((c) => c.id);
    const { results } = await db
      .prepare(`SELECT id, user_id, result FROM applied_commands WHERE id IN (${ids.map(() => "?").join(", ")})`)
      .bind(...ids)
      .all<Stored & { id: string }>();
    for (const r of results) stored.set(r.id, r);
    left--;
  }

  const memberships = new Map<string, Membership>();
  const results: CommandResult[] = [];
  let processed = 0;
  for (const [i, cmd] of commands.entries()) {
    // Un duplicado o un tipo desconocido no hace consultas: no gasta presupuesto.
    const free = stored.has(cmd.id) || !HANDLERS[cmd.type];
    const cost = free ? 0 : (memberships.has(cmd.clubId) ? 0 : MEMBERSHIP_QUERIES) + MAX_HANDLER_READS + MAX_WRITE_QUERIES;
    // Siempre se procesa al menos uno, para que la cola avance aunque el tiempo vaya justo.
    if (cost > left || (processed > 0 && !free && Date.now() >= deadline)) {
      // Se corta aquí y no se salta ninguno: el siguiente podría depender de este.
      for (const rest of commands.slice(i)) {
        results.push({ id: rest.id, status: "deferred", code: "budget", message: "Pendiente: se enviará en la próxima tanda" });
      }
      break;
    }
    left -= cost;
    processed++;
    results.push(await applyOne(db, user, cmd, now, stored, memberships));
  }
  return results;
}

async function applyOne(
  db: D1Database,
  user: PublicUser,
  cmd: Command,
  now: Date,
  stored: Map<string, Stored>,
  memberships: Map<string, Membership>,
): Promise<CommandResult> {
  const previous = stored.get(cmd.id);
  if (previous) return fromStored(cmd, user, previous);

  const handler = HANDLERS[cmd.type];
  if (!handler) {
    return { id: cmd.id, status: "deferred", code: "unknown_command", message: "El servidor aún no admite este cambio: se reintentará" };
  }

  // Hasta aquí nada depende del estado del servidor: si se rechaza, no se guarda.
  let ctx;
  let parsed;
  try {
    const { club, member } = await membership(db, cmd.clubId, user.id, memberships);
    assertWritable(club);
    parsed = handler.schema.safeParse(cmd.payload);
    if (!parsed.success) throw errors.invalidInput(z.flattenError(parsed.error).fieldErrors);
    ctx = { db, now, clientAt: effectiveClientAt(new Date(cmd.clientAt), now), user, club, member };
  } catch (e) {
    if (e instanceof ApiError) return { id: cmd.id, ...rejected(e) };
    console.error(e);
    return { id: cmd.id, status: "error", code: "internal", message: "Error interno. Se reintentará" };
  }

  let outcome: Outcome;
  try {
    const effect = await handler.run(ctx, parsed.data as never);
    outcome = { status: "applied" };
    await db.batch([
      ...effect.statements,
      ...effect.touched.map((t) => changeStatement(db, ctx.club.id, t, now)),
      ...(effect.audit ?? []).map((a) => auditStatement(db, { ...a, clubId: ctx.club.id, actorUserId: user.id }, now)),
      recordStatement(db, user.id, cmd, outcome, now),
    ]);
    // Los permisos solo cambian si se tocó el propio perfil o el servidor: entonces se vuelven a leer.
    if (effect.touched.some((t) => t.entity === "club" || (t.entity === "member" && t.key === ctx.member.id))) {
      memberships.delete(cmd.clubId);
    }
  } catch (e) {
    if (isDuplicateId(e)) return await concurrentDuplicate(db, cmd, user, stored);
    if (e instanceof ApiError) {
      outcome = rejected(e);
    } else if (/UNIQUE constraint failed|CHECK constraint failed|FOREIGN KEY constraint failed/.test(String(e))) {
      outcome = { status: "rejected", code: "conflict", message: "Ese cambio choca con otro que ya está guardado", details: null };
    } else {
      // Fallo inesperado: no se guarda, para que la app lo reintente más tarde.
      console.error(e);
      return { id: cmd.id, status: "error", code: "internal", message: "Error interno. Se reintentará" };
    }
    try {
      await recordStatement(db, user.id, cmd, outcome, now).run();
    } catch (recordError) {
      if (isDuplicateId(recordError)) return await concurrentDuplicate(db, cmd, user, stored);
      console.error(recordError);
      return { id: cmd.id, status: "error", code: "internal", message: "Error interno. Se reintentará" };
    }
  }
  stored.set(cmd.id, { user_id: user.id, result: JSON.stringify(outcome) });
  return { id: cmd.id, ...outcome };
}

async function membership(db: D1Database, clubId: string, userId: string, cache: Map<string, Membership>) {
  let m = cache.get(clubId);
  if (!m) {
    try {
      m = await requireMembership(db, clubId, userId);
    } catch (e) {
      if (!(e instanceof ApiError)) throw e;
      m = e;
    }
    cache.set(clubId, m);
  }
  if (m instanceof ApiError) throw m;
  return m;
}

function rejected(e: ApiError): Outcome {
  return { status: "rejected", code: e.code, message: e.message, details: e.details ?? null };
}

function fromStored(cmd: Command, user: PublicUser, row: Stored): CommandResult {
  if (row.user_id !== user.id) {
    return { id: cmd.id, status: "rejected", code: "invalid_input", message: "Ese id de comando ya se usó", details: null };
  }
  return { id: cmd.id, status: "duplicate", original: JSON.parse(row.result) as Outcome };
}

const isDuplicateId = (e: unknown) => String(e).includes("UNIQUE constraint failed: applied_commands.id");

/** Otro envío con el mismo comando ganó la carrera: se devuelve lo que guardó él. */
async function concurrentDuplicate(db: D1Database, cmd: Command, user: PublicUser, stored: Map<string, Stored>) {
  const row = await db
    .prepare("SELECT user_id, result FROM applied_commands WHERE id = ?")
    .bind(cmd.id)
    .first<Stored>();
  if (!row) return { id: cmd.id, status: "error" as const, code: "internal" as const, message: "Error interno. Se reintentará" };
  stored.set(cmd.id, row);
  return fromStored(cmd, user, row);
}

function recordStatement(db: D1Database, userId: string, cmd: Command, outcome: Outcome, now: Date) {
  return db
    .prepare(
      "INSERT INTO applied_commands (id, user_id, club_id, type, status, result, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(cmd.id, userId, cmd.clubId, cmd.type, outcome.status, JSON.stringify(outcome), now.toISOString());
}
