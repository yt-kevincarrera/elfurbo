import { z } from "zod";
import { canPickMvp } from "../authz";
import { errors } from "../http/errors";
import { votingOver } from "../rules/matchday";
import { remove, upsert } from "../sync/changes";
import { command } from "../sync/command";
import { assertOpen, assertPlayed, findMatchday, key, matchdayId, memberId } from "./pachanga";

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
 * MVP a dedo: si la votación terminó sin votos, un admin elige el MVP entre los que jugaron (él
 * también). `null` lo quita. La hora es la del servidor: el plazo natural tiene que haber pasado.
 */
export const pickMvp = command(z.object({ matchdayId, memberId: memberId.nullable() }), async (ctx, p) => {
  if (!canPickMvp(ctx.member.role)) throw errors.forbidden();
  const md = await findMatchday(ctx, p.matchdayId);
  if (md.seasonClosed) throw errors.seasonClosed();
  assertPlayed(ctx, md);
  if (!votingOver(md, ctx.now, ctx.club.settings.closeAfterHours)) {
    throw errors.invalidState("La votación todavía está abierta. Si cierra sin votos, ahí eliges tú el MVP");
  }
  // Cerrada a mano: solo vale si la cerraron después del plazo. Si no, nadie pudo votar.
  if (md.status === "closed") {
    const closedAt = await ctx.db
      .prepare(
        `SELECT at FROM audit_log
          WHERE club_id = ? AND entity_key = ? AND action = 'matchday.setStatus' AND json_extract(summary, '$.to') = 'closed'
          ORDER BY id DESC LIMIT 1`,
      )
      .bind(ctx.club.id, md.id)
      .first<{ at: string }>();
    const deadline = Date.parse(md.startsAt) + ctx.club.settings.closeAfterHours * 3600_000;
    if (!closedAt || Date.parse(closedAt.at) < deadline) {
      throw errors.invalidState("La cerraron a mano antes de que acabara la votación. Reábrela para que voten; si cierra sin votos, ahí eliges tú");
    }
  }
  const votes = await ctx.db.prepare("SELECT COUNT(*) AS n FROM mvp_votes WHERE matchday_id = ?").bind(md.id).first<{ n: number }>();
  if (votes!.n > 0) throw errors.invalidState("Ya hay votos: el MVP lo decide la votación");
  if (p.memberId !== null) {
    const present = await ctx.db
      .prepare("SELECT 1 FROM attendance WHERE matchday_id = ? AND member_id = ? AND played = 1")
      .bind(md.id, p.memberId)
      .first();
    if (!present) throw errors.notPresent();
  }
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
