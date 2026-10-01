import { z } from "zod";
import { errors } from "../http/errors";
import { remove, upsert } from "../sync/changes";
import { command } from "../sync/command";
import { assertOpen, assertPlayed, findMatchday, key, matchdayId, memberId } from "./pachanga";

/** Mi voto de MVP. Votan los que jugaron, por otro que jugó (con o sin cuenta). Cambiarlo reemplaza. */
export const castVote = command(z.object({ matchdayId, votedFor: memberId }), async (ctx, p) => {
  if (p.votedFor === ctx.member.id) throw errors.invalidInput({ votedFor: ["No puedes votarte a ti mismo"] });
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
