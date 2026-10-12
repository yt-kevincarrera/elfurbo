import { z } from "zod";
import { canPickMvp } from "../authz";
import { errors } from "../http/errors";
import { isClosed } from "../rules/matchday";
import { remove, upsert } from "../sync/changes";
import { command } from "../sync/command";
import { assertActiveMembers, assertOpen, assertPlayed, findMatchday, key, matchdayId, memberId } from "./pachanga";

/** Mi voto de MVP. Votan los que jugaron, por otro que jugó (con o sin cuenta). Cambiarlo reemplaza. */
export const castVote = command(z.object({ matchdayId, votedFor: memberId }), async (ctx, p) => {
  if (p.votedFor === ctx.member.id) throw errors.invalidInput({ votedFor: ["No vale votarte a ti mismo"] });
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  assertPlayed(ctx, md);
  const { results } = await ctx.db
    .prepare("SELECT member_id FROM attendance WHERE matchday_id = ? AND played = 1 AND member_id IN (?, ?)")
    .bind(md.id, ctx.member.id, p.votedFor)
    .all<{ member_id: string }>();
  const present = new Set(results.map((r) => r.member_id));
  if (!present.has(ctx.member.id) || !present.has(p.votedFor)) throw errors.notPresent();
  const id = key(md.id, ctx.member.id);
  return {
    statements: [
      ctx.db
        .prepare(
          `INSERT INTO mvp_votes (id, club_id, matchday_id, voter_id, voted_for, updated_at) VALUES (?, ?, ?, ?, ?, ?)
           ON CONFLICT(id) DO UPDATE SET voted_for = excluded.voted_for, updated_at = excluded.updated_at`,
        )
        .bind(id, ctx.club.id, md.id, ctx.member.id, p.votedFor, ctx.now.toISOString()),
    ],
    touched: [upsert("vote", id)],
  };
});

export const clearVote = command(z.object({ matchdayId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  const id = key(md.id, ctx.member.id);
  return {
    statements: [ctx.db.prepare("DELETE FROM mvp_votes WHERE id = ?").bind(id)],
    touched: [remove("vote", id)],
  };
});

/**
 * MVP a dedo: si la jornada está cerrada (a mano o por plazo) y nadie votó, un admin elige el MVP
 * entre los miembros activos (él también). `null` lo quita. Los votos ganan siempre.
 */
export const pickMvp = command(z.object({ matchdayId, memberId: memberId.nullable() }), async (ctx, p) => {
  if (!canPickMvp(ctx.member.role)) throw errors.forbidden();
  const md = await findMatchday(ctx, p.matchdayId);
  if (md.seasonClosed) throw errors.seasonClosed();
  assertPlayed(ctx, md);
  // Con la hora del servidor: una reabierta sigue abierta.
  if (!isClosed(md, ctx.now, ctx.club.settings.closeAfterHours)) {
    throw errors.invalidState("La votación todavía está abierta. Cuando cierre sin votos, ahí eliges tú el MVP");
  }
  const votes = await ctx.db.prepare("SELECT COUNT(*) AS n FROM mvp_votes WHERE matchday_id = ?").bind(md.id).first<{ n: number }>();
  if (votes!.n > 0) throw errors.invalidState("Ya hay votos: el MVP lo decide la votación");
  if (p.memberId !== null) await assertActiveMembers(ctx, [p.memberId], "memberId");
  return {
    statements: [
      ctx.db
        .prepare("UPDATE matchdays SET mvp_pick = ?, mvp_pick_by = ?, updated_at = ? WHERE id = ?")
        .bind(p.memberId, p.memberId === null ? null : ctx.member.id, ctx.now.toISOString(), md.id),
    ],
    touched: [upsert("matchday", md.id)],
    audit: [
      {
        action: "matchday.mvpPick",
        entity: "matchday",
        entityKey: md.id,
        summary: { memberId: p.memberId, self: p.memberId === ctx.member.id },
      },
    ],
  };
});
