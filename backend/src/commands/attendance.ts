import { z } from "zod";
import { canActForOthers, canDecideReports } from "../authz";
import { errors } from "../http/errors";
import { consumeAttempt } from "../auth/rate-limit";
import { checkinValid } from "../rules/checkin";
import { acceptsIntent } from "../rules/matchday";
import { upsert, type SyncEntity } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { assertActiveMembers, assertOpen, assertPlayed, childChanges, findMatchday, key, matchdayId, memberId } from "./pachanga";

/** Escribe `played` de un miembro conservando su intención. */
export function playedStatement(ctx: CommandContext, matchday: string, member: string, played: boolean) {
  return ctx.db
    .prepare(
      `INSERT INTO attendance (id, club_id, matchday_id, member_id, played, played_set_by, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET played = excluded.played, played_set_by = excluded.played_set_by, updated_at = excluded.updated_at`,
    )
    .bind(key(matchday, member), ctx.club.id, matchday, member, played ? 1 : 0, ctx.member.id, ctx.now.toISOString());
}

/** Borra filas hijas de una jornada avisando a los teléfonos (`changes`). */
function dropRows(ctx: CommandContext, table: string, entity: SyncEntity, where: string, ...binds: unknown[]) {
  return [
    childChanges(ctx, table, entity, "delete", where, ...binds),
    ctx.db.prepare(`DELETE FROM ${table} WHERE ${where}`).bind(...binds),
  ];
}

/**
 * Escribe la presencia. "No fue" además lo saca de la jornada: se va lo que pedía haber jugado (su
 * reporte con sus confirmaciones, las confirmaciones que dio y los votos de MVP que dio o recibió).
 * Si no, el que se añadió por error seguía contando la jornada por su reporte confirmado. Un reporte
 * rechazado se queda: no cuenta y el rechazo es definitivo.
 */
function presenceStatements(ctx: CommandContext, matchday: string, member: string, played: boolean) {
  if (played) return [playedStatement(ctx, matchday, member, true)];
  const report = key(matchday, member);
  return [
    ...dropRows(
      ctx,
      "report_confirmations",
      "confirmation",
      "matchday_id = ? AND (confirmer_id = ? OR (member_id = ? AND NOT EXISTS (SELECT 1 FROM reports WHERE id = ? AND decision = 'rejected')))",
      matchday,
      member,
      member,
      report,
    ),
    ...dropRows(ctx, "mvp_votes", "vote", "matchday_id = ? AND (voter_id = ? OR voted_for = ?)", matchday, member, member),
    ...dropRows(ctx, "reports", "report", "id = ? AND decision IS NOT 'rejected'", report),
    playedStatement(ctx, matchday, member, false),
  ];
}

/** Voy / Quizás / No voy (o null para quitarla). Solo antes de que termine la jornada. */
export const setIntent = command(
  z.object({ matchdayId, intent: z.enum(["yes", "no", "maybe"]).nullable() }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    // La intención se juzga con la hora del teléfono: se marcó antes aunque llegue después.
    if (!acceptsIntent(md, ctx.clientAt)) throw errors.matchdayAlreadyPlayed();
    const id = key(md.id, ctx.member.id);
    return {
      statements: [
        ctx.db
          .prepare(
            // `intent_at` es el turno en la lista de espera: se toma al decir "Voy" y se pierde al bajarse.
            `INSERT INTO attendance (id, club_id, matchday_id, member_id, intent, intent_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, CASE WHEN ?5 = 'yes' THEN ?6 END, ?6)
             ON CONFLICT(id) DO UPDATE SET
               intent = excluded.intent,
               intent_at = CASE WHEN excluded.intent IS NOT 'yes' THEN NULL WHEN attendance.intent = 'yes' THEN attendance.intent_at ELSE excluded.intent_at END,
               updated_at = excluded.updated_at`,
          )
          .bind(id, ctx.club.id, md.id, ctx.member.id, p.intent, ctx.now.toISOString()),
      ],
      touched: [upsert("attendance", id)],
    };
  },
);

const CHECKIN_SPAN_MS = 3 * 60 * 60 * 1000;
/** Sin señal se manda después, pero no días después: así no se usa un código de otro día. */
const CHECKIN_LATE_MS = 24 * 60 * 60 * 1000;
/** Cada intento cuenta: 10 por hora y jugador, para que el código no se adivine a fuerza de probar. */
const CHECKIN_ATTEMPTS = { max: 10, windowMinutes: 60 };

/**
 * "Estoy aquí" con el código que enseña el staff (spec 2.0 §8.1): marca que jugó y que lo comprobó.
 * El código se juzga con la hora del teléfono (se pudo escribir sin señal), y solo cerca de la jornada.
 */
export const checkIn = command(z.object({ matchdayId, code: z.string().regex(/^\d{6}$/) }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  const start = new Date(md.startsAt).getTime();
  const end = start + md.durationMinutes * 60_000;
  const at = ctx.clientAt.getTime();
  if (at < start - CHECKIN_SPAN_MS || at > end + CHECKIN_SPAN_MS || ctx.now.getTime() - at > CHECKIN_LATE_MS) {
    throw errors.checkinClosed();
  }
  // Fuera del batch del comando: el intento se cuenta aunque el código no valga.
  await consumeAttempt(ctx.db, { key: `checkin:${ctx.member.id}`, ...CHECKIN_ATTEMPTS }, ctx.now);
  const row = await ctx.db.prepare("SELECT checkin_secret FROM clubs WHERE id = ?").bind(ctx.club.id).first<{ checkin_secret: string | null }>();
  if (!row?.checkin_secret || !(await checkinValid(row.checkin_secret, ctx.clientAt, p.code))) throw errors.checkinCode();
  const id = key(md.id, ctx.member.id);
  const now = ctx.now.toISOString();
  return {
    statements: [
      ctx.db
        .prepare(
          `INSERT INTO attendance (id, club_id, matchday_id, member_id, played, played_set_by, checked_in_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, 1, ?4, ?5, ?5)
           ON CONFLICT(id) DO UPDATE SET played = 1, played_set_by = ?4, checked_in_at = COALESCE(attendance.checked_in_at, ?5), updated_at = ?5`,
        )
        .bind(id, ctx.club.id, md.id, ctx.member.id, now),
    ],
    touched: [upsert("attendance", id)],
  };
});

/** "Jugué" / "No fui". Solo cuando la jornada ya terminó. */
export const setPlayed = command(z.object({ matchdayId, played: z.boolean() }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  assertPlayed(ctx, md);
  return {
    statements: presenceStatements(ctx, md.id, ctx.member.id, p.played),
    touched: [upsert("attendance", key(md.id, ctx.member.id))],
  };
});

/** Pasar lista: el staff marca quién jugó (con o sin cuenta). */
export const rollCall = command(
  z.object({
    matchdayId,
    entries: z
      .array(z.object({ memberId, played: z.boolean() }))
      .min(1)
      .max(90)
      .refine((e) => new Set(e.map((x) => x.memberId)).size === e.length, { error: "Hay jugadores repetidos" }),
  }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    assertPlayed(ctx, md);
    await assertActiveMembers(ctx, p.entries.map((e) => e.memberId), "entries");
    // "No fue" borra su reporte: lo que corrigió el admin solo lo deshace owner o admin (como en loadReportFor).
    const absent = p.entries.filter((e) => !e.played).map((e) => key(md.id, e.memberId));
    if (absent.length > 0 && !canDecideReports(ctx.member.role)) {
      const corrected = await ctx.db
        .prepare(`SELECT 1 FROM reports WHERE corrected_by IS NOT NULL AND id IN (${absent.map(() => "?").join(", ")}) LIMIT 1`)
        .bind(...absent)
        .first();
      if (corrected) throw errors.forbidden();
    }
    return {
      statements: p.entries.flatMap((e) => presenceStatements(ctx, md.id, e.memberId, e.played)),
      touched: p.entries.map((e) => upsert("attendance", key(md.id, e.memberId))),
    };
  },
);
