import { z } from "zod";
import { canActForOthers, canDecideReports } from "../authz";
import { errors } from "../http/errors";
import { remove, upsert } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { playedStatement } from "./attendance";
import { assertActiveMembers, assertOpen, assertPlayed, childChanges, findMatchday, goalsOrAssists, key, matchdayId, memberId } from "./pachanga";

const note = z.string().trim().max(200).nullable();

type ReportRow = { member_id: string; decision: "confirmed" | "rejected" | null; corrected_by: string | null };

async function findReport(ctx: CommandContext, matchday: string, member: string) {
  return ctx.db
    .prepare("SELECT member_id, decision, corrected_by FROM reports WHERE id = ?")
    .bind(key(matchday, member))
    .first<ReportRow>();
}

/** Quita las confirmaciones de un reporte (con sus `changes`): editar un reporte lo vuelve pendiente. */
function clearConfirmations(ctx: CommandContext, matchday: string, member: string) {
  return [
    childChanges(ctx, "report_confirmations", "confirmation", "delete", "matchday_id = ? AND member_id = ?", matchday, member),
    ctx.db.prepare("DELETE FROM report_confirmations WHERE matchday_id = ? AND member_id = ?").bind(matchday, member),
  ];
}

/** Escribe un reporte nuevo (o reemplaza el que había): sin decisión ni corrección. */
function writeReport(ctx: CommandContext, matchday: string, member: string, goals: number, assists: number, n: string | null) {
  return ctx.db
    .prepare(
      `INSERT INTO reports (id, club_id, matchday_id, member_id, goals, assists, note, loaded_by, decision, corrected_by, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)
       ON CONFLICT(id) DO UPDATE SET goals = excluded.goals, assists = excluded.assists, note = excluded.note,
         loaded_by = excluded.loaded_by, decision = NULL, corrected_by = NULL, updated_at = excluded.updated_at`,
    )
    .bind(key(matchday, member), ctx.club.id, matchday, member, goals, assists, n, ctx.member.id, ctx.now.toISOString());
}

/**
 * Mi reporte de la jornada (crear o editar). Cuenta como "jugué". Editarlo lo vuelve pendiente; si el
 * admin lo rechazó, ya no se puede cambiar (rechazo definitivo).
 */
export const upsertReport = command(
  z.object({ matchdayId, goals: goalsOrAssists, assists: goalsOrAssists, note: note.optional() }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    assertPlayed(ctx, md);
    const existing = await findReport(ctx, md.id, ctx.member.id);
    if (existing?.decision === "rejected") throw errors.reportRejected();
    const id = key(md.id, ctx.member.id);
    return {
      statements: [
        ...clearConfirmations(ctx, md.id, ctx.member.id),
        writeReport(ctx, md.id, ctx.member.id, p.goals, p.assists, p.note ?? null),
        playedStatement(ctx, md.id, ctx.member.id, true),
      ],
      touched: [upsert("report", id), upsert("attendance", id)],
    };
  },
);

export const deleteReport = command(z.object({ matchdayId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  const existing = await findReport(ctx, md.id, ctx.member.id);
  if (!existing) throw errors.notFound();
  if (existing.decision === "rejected") throw errors.reportRejected();
  const id = key(md.id, ctx.member.id);
  return {
    statements: [...clearConfirmations(ctx, md.id, ctx.member.id), ctx.db.prepare("DELETE FROM reports WHERE id = ?").bind(id)],
    touched: [remove("report", id)],
  };
});

/** El staff carga el reporte de otro (también de un jugador sin cuenta). Cuenta al momento. */
export const loadReportFor = command(
  z.object({ matchdayId, memberId, goals: goalsOrAssists, assists: goalsOrAssists, note: note.optional() }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    assertPlayed(ctx, md);
    await assertActiveMembers(ctx, [p.memberId], "memberId");
    // Cargar por otro no sirve para saltarse una decisión: un rechazo es definitivo (también para el
    // staff: primero hay que quitar la decisión), y una corrección solo la rehace owner o admin.
    const existing = await findReport(ctx, md.id, p.memberId);
    if (existing?.decision === "rejected") throw errors.reportRejected();
    if (existing?.corrected_by && !canDecideReports(ctx.member.role)) throw errors.forbidden();
    const id = key(md.id, p.memberId);
    return {
      statements: [
        ...clearConfirmations(ctx, md.id, p.memberId),
        writeReport(ctx, md.id, p.memberId, p.goals, p.assists, p.note ?? null),
        playedStatement(ctx, md.id, p.memberId, true),
      ],
      touched: [upsert("report", id), upsert("attendance", id)],
      audit: [{ action: "report.loadFor", entity: "report", entityKey: id, summary: { goals: p.goals, assists: p.assists } }],
    };
  },
);

/** Un compañero que jugó confirma el reporte de otro. Confirmar dos veces no hace nada. */
export const confirmReport = command(z.object({ matchdayId, memberId }), async (ctx, p) => {
  if (p.memberId === ctx.member.id) throw errors.forbidden();
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  const existing = await findReport(ctx, md.id, p.memberId);
  if (!existing) throw errors.notFound();
  if (existing.decision === "rejected") throw errors.reportRejected();
  const present = await ctx.db
    .prepare("SELECT 1 FROM attendance WHERE id = ? AND played = 1")
    .bind(key(md.id, ctx.member.id))
    .first();
  if (!present) throw errors.notPresent();
  const id = key(md.id, p.memberId, ctx.member.id);
  return {
    statements: [
      ctx.db
        .prepare(
          "INSERT OR IGNORE INTO report_confirmations (id, club_id, matchday_id, member_id, confirmer_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(id, ctx.club.id, md.id, p.memberId, ctx.member.id, ctx.now.toISOString()),
    ],
    touched: [upsert("confirmation", id)],
  };
});

export const unconfirmReport = command(z.object({ matchdayId, memberId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  const id = key(md.id, p.memberId, ctx.member.id);
  return {
    statements: [ctx.db.prepare("DELETE FROM report_confirmations WHERE id = ?").bind(id)],
    touched: [remove("confirmation", id)],
  };
});

/** Owner o admin: confirmar, rechazar (definitivo para el autor) o quitar la decisión (null). */
export const decideReport = command(
  z.object({ matchdayId, memberId, decision: z.enum(["confirmed", "rejected"]).nullable() }),
  async (ctx, p) => {
    if (!canDecideReports(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    if (!(await findReport(ctx, md.id, p.memberId))) throw errors.notFound();
    const id = key(md.id, p.memberId);
    return {
      statements: [
        ctx.db.prepare("UPDATE reports SET decision = ?, updated_at = ? WHERE id = ?").bind(p.decision, ctx.now.toISOString(), id),
      ],
      touched: [upsert("report", id)],
      audit: [{ action: "report.decide", entity: "report", entityKey: id, summary: { decision: p.decision } }],
    };
  },
);

/** Owner o admin corrigen los números: queda confirmado y marcado como corregido. */
export const correctReport = command(
  z.object({ matchdayId, memberId, goals: goalsOrAssists, assists: goalsOrAssists }),
  async (ctx, p) => {
    if (!canDecideReports(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    if (!(await findReport(ctx, md.id, p.memberId))) throw errors.notFound();
    const id = key(md.id, p.memberId);
    return {
      statements: [
        ctx.db
          .prepare("UPDATE reports SET goals = ?, assists = ?, decision = 'confirmed', corrected_by = ?, updated_at = ? WHERE id = ?")
          .bind(p.goals, p.assists, ctx.member.id, ctx.now.toISOString(), id),
      ],
      touched: [upsert("report", id)],
      audit: [{ action: "report.correct", entity: "report", entityKey: id, summary: { goals: p.goals, assists: p.assists } }],
    };
  },
);

