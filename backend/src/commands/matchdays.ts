import { z } from "zod";
import { canActForOthers, canCreateMatchday, canEditMatchday, canManageMatchday } from "../authz";
import { errors } from "../http/errors";
import { remove, upsert, type Touch } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { assertActiveMembers, assertOpen, CHILDREN, childChanges, findMatchday, key, matchdayId, type Matchday } from "./pachanga";

const startsAt = z.iso.datetime({ offset: true }).transform((s) => new Date(s).toISOString());
/** Opcional: la jornada dura lo que quieran (0 = se reporta desde que empieza). */
const durationMinutes = z.number().int().min(0).max(600);
const place = z.string().trim().max(80).nullable();
const notes = z.string().trim().max(300).nullable();
const seasonId = z.string().min(1).max(64);
/** Cupo de la jornada (0 = sin límite); los de más quedan en lista de espera. */
const maxPlayers = z.number().int().min(0).max(60);

/** ¿Hay datos de alguien que no sea quien la creó? (asistencia, reportes o votos). */
async function hasOthersData(ctx: CommandContext, md: Matchday) {
  const row = await ctx.db
    .prepare(
      `SELECT EXISTS (SELECT 1 FROM attendance WHERE matchday_id = ?1 AND member_id <> ?2)
           OR EXISTS (SELECT 1 FROM reports WHERE matchday_id = ?1 AND member_id <> ?2)
           OR EXISTS (SELECT 1 FROM mvp_votes WHERE matchday_id = ?1 AND voter_id <> ?2) AS others`,
    )
    .bind(md.id, md.createdBy)
    .first<{ others: number }>();
  return row!.others === 1;
}

async function assertCanManage(ctx: CommandContext, md: Matchday) {
  const isCreator = md.createdBy === ctx.member.id;
  // La consulta solo hace falta para el player que la creó; el staff puede siempre.
  const others = ctx.member.role === "player" && isCreator ? await hasOthersData(ctx, md) : false;
  if (!canManageMatchday(ctx.member.role, { isCreator, hasOthersData: others })) throw errors.forbidden();
}

/** La temporada indicada (o la activa) tiene que existir en el servidor y no estar cerrada. */
async function resolveSeason(ctx: CommandContext, id: string | undefined) {
  const row = id
    ? await ctx.db
        .prepare("SELECT id, is_closed FROM seasons WHERE id = ? AND club_id = ?")
        .bind(id, ctx.club.id)
        .first<{ id: string; is_closed: number }>()
    : await ctx.db
        .prepare("SELECT id, is_closed FROM seasons WHERE club_id = ? AND is_active = 1")
        .bind(ctx.club.id)
        .first<{ id: string; is_closed: number }>();
  if (!row) throw id ? errors.notFound() : errors.noActiveSeason();
  if (row.is_closed === 1) throw errors.seasonClosed();
  return row.id;
}

/** Una jornada. El id lo pone la app; repetir cada semana = un comando por fecha. */
export const createMatchday = command(
  z.object({
    id: z.uuid(),
    startsAt,
    durationMinutes: durationMinutes.default(0),
    place: place.optional(),
    notes: notes.optional(),
    seasonId: seasonId.optional(),
    maxPlayers: maxPlayers.optional(),
  }),
  async (ctx, p) => {
    if (!canCreateMatchday(ctx.member.role, ctx.club.settings.matchdayCreators)) throw errors.forbidden();
    const season = await resolveSeason(ctx, p.seasonId);
    const at = ctx.now.toISOString();
    return {
      statements: [
        ctx.db
          .prepare(
            `INSERT INTO matchdays (id, club_id, season_id, starts_at, duration_minutes, place, notes, max_players, created_by, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(
            p.id,
            ctx.club.id,
            season,
            p.startsAt,
            p.durationMinutes,
            p.place ?? null,
            p.notes ?? null,
            p.maxPlayers ?? ctx.club.settings.maxPlayers,
            ctx.member.id,
            at,
            at,
          ),
      ],
      touched: [upsert("matchday", p.id)],
    };
  },
);

/** Fecha, duración, lugar, notas o temporada. Lo que no venga se queda como está; `null` borra. */
export const updateMatchday = command(
  z
    .object({
      matchdayId,
      startsAt: startsAt.optional(),
      durationMinutes: durationMinutes.optional(),
      place: place.optional(),
      notes: notes.optional(),
      seasonId: seasonId.optional(),
      maxPlayers: maxPlayers.optional(),
    })
    .refine((p) => Object.keys(p).length > 1, { error: "Nada que cambiar" }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    if (!canEditMatchday(ctx.member.role, { isCreator: md.createdBy === ctx.member.id })) throw errors.forbidden();
    // Cerrada no se toca (el staff la reabre); si no, mover la fecha la "reabriría".
    assertOpen(ctx, md);
    // El player que la creó no mueve cuándo ni en qué temporada fue si ya hay datos de otros.
    const movesIt = p.startsAt !== undefined || p.durationMinutes !== undefined || p.seasonId !== undefined;
    if (ctx.member.role === "player" && movesIt && (await hasOthersData(ctx, md))) throw errors.forbidden();
    const season = p.seasonId === undefined ? md.seasonId : await resolveSeason(ctx, p.seasonId);
    return {
      statements: [
        ctx.db
          .prepare(
            `UPDATE matchdays SET starts_at = ?, duration_minutes = ?,
                    place = CASE WHEN ? THEN ? ELSE place END,
                    notes = CASE WHEN ? THEN ? ELSE notes END,
                    max_players = COALESCE(?, max_players), season_id = ?, updated_at = ?
              WHERE id = ?`,
          )
          .bind(
            p.startsAt ?? md.startsAt,
            p.durationMinutes ?? md.durationMinutes,
            p.place !== undefined ? 1 : 0,
            p.place ?? null,
            p.notes !== undefined ? 1 : 0,
            p.notes ?? null,
            p.maxPlayers ?? null,
            season,
            ctx.now.toISOString(),
            md.id,
          ),
      ],
      touched: [upsert("matchday", md.id)],
    };
  },
);

/** Cancelar, reactivar, cerrar a mano o reabrir. */
export const setMatchdayStatus = command(
  z.object({ matchdayId, status: z.enum(["scheduled", "cancelled", "closed", "reopened"]) }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    await assertCanManage(ctx, md);
    if (md.seasonClosed) throw errors.seasonClosed();
    return {
      statements: [
        ctx.db.prepare("UPDATE matchdays SET status = ?, updated_at = ? WHERE id = ?").bind(p.status, ctx.now.toISOString(), md.id),
      ],
      touched: [upsert("matchday", md.id)],
      audit: [{ action: "matchday.setStatus", entity: "matchday", entityKey: md.id, summary: { from: md.status, to: p.status } }],
    };
  },
);

/** Borra la jornada y todo lo que cuelga de ella (asistencia, reportes, confirmaciones, votos). */
export const deleteMatchday = command(z.object({ matchdayId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  await assertCanManage(ctx, md);
  const statements: D1PreparedStatement[] = [];
  for (const { table, entity } of CHILDREN) {
    statements.push(childChanges(ctx, table, entity, "delete", "matchday_id = ?", md.id));
    statements.push(ctx.db.prepare(`DELETE FROM ${table} WHERE matchday_id = ?`).bind(md.id));
  }
  statements.push(ctx.db.prepare("DELETE FROM matchdays WHERE id = ?").bind(md.id));
  return {
    statements,
    touched: [remove("matchday", md.id)],
    audit: [{ action: "matchday.delete", entity: "matchday", entityKey: md.id }],
  };
});

/** Equipos (opcional). `null` los quita. Solo miembros activos del servidor. */
export const saveTeams = command(
  z.object({
    matchdayId,
    teams: z.object({ a: z.array(z.string().min(1).max(64)).max(40), b: z.array(z.string().min(1).max(64)).max(40) }).nullable(),
  }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    if (p.teams) await assertActiveMembers(ctx, [...p.teams.a, ...p.teams.b], "teams");
    return {
      statements: [
        ctx.db
          .prepare("UPDATE matchdays SET teams = ?, updated_at = ? WHERE id = ?")
          .bind(p.teams ? JSON.stringify(p.teams) : null, ctx.now.toISOString(), md.id),
      ],
      touched: [upsert("matchday", md.id)],
    };
  },
);

type ChildRow = { t: string; id: string; member_id: string; confirmer_id: string | null; updated_at: string; data: string };

/**
 * Une dos jornadas duplicadas (dos personas la crearon sin señal). Todo lo de `fromId` pasa a
 * `intoId`; si una persona tiene datos en las dos, se queda el más reciente (y las confirmaciones
 * siguen a su reporte). `fromId` se borra.
 */
export const mergeMatchdays = command(
  z.object({ fromId: matchdayId, intoId: matchdayId }).refine((p) => p.fromId !== p.intoId, { error: "Son la misma jornada" }),
  async (ctx, p) => {
    const from = await findMatchday(ctx, p.fromId);
    const into = await findMatchday(ctx, p.intoId);
    await assertCanManage(ctx, from);
    if (!canEditMatchday(ctx.member.role, { isCreator: into.createdBy === ctx.member.id })) throw errors.forbidden();
    assertOpen(ctx, from);
    assertOpen(ctx, into);

    const { results } = await ctx.db
      .prepare(
        `SELECT 'attendance' AS t, id, member_id, NULL AS confirmer_id, updated_at,
                json_object('intent', intent, 'played', played, 'played_set_by', played_set_by) AS data
           FROM attendance WHERE matchday_id IN (?1, ?2)
         UNION ALL
         SELECT 'reports', id, member_id, NULL, updated_at,
                json_object('goals', goals, 'assists', assists, 'note', note, 'loaded_by', loaded_by,
                            'decision', decision, 'corrected_by', corrected_by)
           FROM reports WHERE matchday_id IN (?1, ?2)
         UNION ALL
         SELECT 'report_confirmations', id, member_id, confirmer_id, created_at, '{}'
           FROM report_confirmations WHERE matchday_id IN (?1, ?2)
         UNION ALL
         SELECT 'mvp_votes', id, voter_id, NULL, updated_at, json_object('voted_for', voted_for)
           FROM mvp_votes WHERE matchday_id IN (?1, ?2)`,
      )
      .bind(from.id, into.id)
      .all<ChildRow>();

    const isFrom = (r: ChildRow) => r.id.startsWith(`${from.id}:`);
    const statements: D1PreparedStatement[] = [];
    const touched: Touch[] = [];
    const entityOf: Record<string, Touch["entity"]> = {
      attendance: "attendance",
      reports: "report",
      report_confirmations: "confirmation",
      mvp_votes: "vote",
    };

    // Asistencia: campo a campo. La intención y la presencia las escriben personas distintas en
    // momentos distintos (un "Voy" tardío no puede borrar el "jugó" de pasar lista).
    const attendance = new Map<string, { from?: ChildRow; into?: ChildRow }>();
    for (const r of results.filter((x) => x.t === "attendance")) {
      const slot = attendance.get(r.member_id) ?? {};
      slot[isFrom(r) ? "from" : "into"] = r;
      attendance.set(r.member_id, slot);
    }
    for (const [member, { from: f, into: i }] of attendance) {
      if (!f) continue;
      statements.push(mergeAttendance(ctx, into.id, member, f, i));
      touched.push(upsert("attendance", key(into.id, member)));
    }

    // Reportes y votos: gana el más reciente; pero un reporte rechazado nunca pierde (es definitivo).
    const reportFromWins = new Set<string>();
    const rejected = (r: ChildRow) => (JSON.parse(r.data) as { decision?: string }).decision === "rejected";
    for (const table of ["reports", "mvp_votes"]) {
      const byMember = new Map<string, { from?: ChildRow; into?: ChildRow }>();
      for (const r of results.filter((x) => x.t === table)) {
        const slot = byMember.get(r.member_id) ?? {};
        slot[isFrom(r) ? "from" : "into"] = r;
        byMember.set(r.member_id, slot);
      }
      for (const [member, { from: f, into: i }] of byMember) {
        if (!f) continue;
        const fromWins =
          !i ||
          (table === "reports" && rejected(f) !== rejected(i) ? rejected(f) : f.updated_at > i.updated_at);
        if (fromWins) {
          if (table === "reports") reportFromWins.add(member);
          statements.push(copyInto(ctx, table, f, into.id, member));
          touched.push(upsert(entityOf[table]!, key(into.id, member)));
        }
      }
    }

    // Confirmaciones: si ganó el reporte de `fromId`, se quedan las suyas y se van las de `intoId`.
    for (const r of results.filter((x) => x.t === "report_confirmations")) {
      const wins = reportFromWins.has(r.member_id);
      if (isFrom(r) && wins) {
        const id = key(into.id, r.member_id, r.confirmer_id!);
        statements.push(
          ctx.db
            .prepare(
              "INSERT OR REPLACE INTO report_confirmations (id, club_id, matchday_id, member_id, confirmer_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(id, ctx.club.id, into.id, r.member_id, r.confirmer_id, r.updated_at),
        );
        touched.push(upsert("confirmation", id));
      } else if (!isFrom(r) && wins && !results.some((x) => x.t === "report_confirmations" && isFrom(x) && x.member_id === r.member_id && x.confirmer_id === r.confirmer_id)) {
        statements.push(ctx.db.prepare("DELETE FROM report_confirmations WHERE id = ?").bind(r.id));
        touched.push(remove("confirmation", r.id));
      }
    }

    // Todo lo de `fromId` desaparece, y `fromId` también.
    for (const { table, entity } of CHILDREN) {
      statements.push(childChanges(ctx, table, entity, "delete", "matchday_id = ?", from.id));
      statements.push(ctx.db.prepare(`DELETE FROM ${table} WHERE matchday_id = ?`).bind(from.id));
    }
    statements.push(ctx.db.prepare("DELETE FROM matchdays WHERE id = ?").bind(from.id));
    touched.push(remove("matchday", from.id));

    return {
      statements,
      touched,
      audit: [{ action: "matchday.merge", entity: "matchday", entityKey: into.id, summary: { from: from.id } }],
    };
  },
);

/** Asistencia unida: la intención más reciente que haya, y la presencia más reciente que haya. */
function mergeAttendance(ctx: CommandContext, intoId: string, member: string, f: ChildRow, i: ChildRow | undefined) {
  type A = { intent: string | null; played: number | null; played_set_by: string | null };
  const rows = [f, i].filter((r): r is ChildRow => r !== undefined).sort((a, b) => b.updated_at.localeCompare(a.updated_at));
  const data = rows.map((r) => JSON.parse(r.data) as A);
  const intent = data.find((d) => d.intent !== null)?.intent ?? null;
  const presence = data.find((d) => d.played !== null);
  return ctx.db
    .prepare(
      `INSERT OR REPLACE INTO attendance (id, club_id, matchday_id, member_id, intent, played, played_set_by, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(key(intoId, member), ctx.club.id, intoId, member, intent, presence?.played ?? null, presence?.played_set_by ?? null, rows[0]!.updated_at);
}

/** Copia el reporte o el voto ganador de `fromId` a `intoId` (reemplazando el que hubiera). */
function copyInto(ctx: CommandContext, table: string, row: ChildRow, intoId: string, member: string) {
  const d = JSON.parse(row.data) as Record<string, unknown>;
  const id = key(intoId, member);
  if (table === "reports") {
    return ctx.db
      .prepare(
        `INSERT OR REPLACE INTO reports (id, club_id, matchday_id, member_id, goals, assists, note, loaded_by, decision, corrected_by, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(id, ctx.club.id, intoId, member, d.goals, d.assists, d.note ?? null, d.loaded_by, d.decision ?? null, d.corrected_by ?? null, row.updated_at);
  }
  return ctx.db
    .prepare("INSERT OR REPLACE INTO mvp_votes (id, club_id, matchday_id, voter_id, voted_for, updated_at) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(id, ctx.club.id, intoId, member, d.voted_for, row.updated_at);
}
