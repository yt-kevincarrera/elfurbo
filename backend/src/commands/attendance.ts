import { z } from "zod";
import { canActForOthers } from "../authz";
import { errors } from "../http/errors";
import { checkinValid } from "../rules/checkin";
import { acceptsIntent } from "../rules/matchday";
import { upsert } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { assertActiveMembers, assertOpen, assertPlayed, findMatchday, key, matchdayId, memberId } from "./pachanga";

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

/**
 * "Estoy aquí" con el código que enseña el staff (spec 2.0 §8.1): marca que jugó y que lo comprobó.
 * El código se juzga con la hora del teléfono (se pudo escribir sin señal), y solo cerca de la jornada.
 */
export const checkIn = command(z.object({ matchdayId, code: z.string().regex(/^\d{6}$/) }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  if (md.status === "cancelled") throw errors.invalidState("La jornada se suspendió");
  const start = new Date(md.startsAt).getTime();
  const end = start + md.durationMinutes * 60_000;
  const at = ctx.clientAt.getTime();
  if (at < start - CHECKIN_SPAN_MS || at > end + CHECKIN_SPAN_MS) throw errors.checkinClosed();
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
    statements: [playedStatement(ctx, md.id, ctx.member.id, p.played)],
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
    return {
      statements: p.entries.map((e) => playedStatement(ctx, md.id, e.memberId, e.played)),
      touched: p.entries.map((e) => upsert("attendance", key(md.id, e.memberId))),
    };
  },
);
