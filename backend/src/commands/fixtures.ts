import { z } from "zod";
import { isAdmin, isStaff } from "../authz";
import { errors } from "../http/errors";
import { loserOf, winnerOf, type KnockoutFixture } from "../rules/knockout";
import { upsert, type Touch } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { assertNotFinished, loadTournament } from "./tournament";

const id = z.string().min(1).max(64);

const sourceSchema = z
  .object({ winnerOf: id.optional(), loserOf: id.optional(), group: z.string().max(4).optional(), pos: z.number().int().min(1).max(8).optional() })
  .strict()
  .refine((s) => Object.keys(s).length > 0, { error: "Fuente vacía" });

const draftSchema = z
  .object({
    id: z.uuid(),
    stage: z.enum(["league", "group", "knockout", "third"]),
    round: z.number().int().min(1).max(100),
    groupLabel: z.string().min(1).max(4).nullable().optional(),
    leg: z.number().int().min(1).max(2).default(1),
    slot: z.number().int().min(0).max(64).nullable().optional(),
    homeTeamId: id.nullable().optional(),
    awayTeamId: id.nullable().optional(),
    homeSource: sourceSchema.nullable().optional(),
    awaySource: sourceSchema.nullable().optional(),
    startsAt: z.iso.datetime({ offset: true }).nullable().optional(),
  })
  .strict();

/** Las fases que se generan (y se borran) juntas. */
const FAMILY = { league: ["league"], group: ["group"], knockout: ["knockout", "third"] } as const;

type FixtureRow = KnockoutFixture & {
  id: string;
  stage: string;
  scorer_member_id: string | null;
  home_source: string | null;
  away_source: string | null;
};

async function findFixture(ctx: CommandContext, fixtureId: string): Promise<FixtureRow> {
  const r = await ctx.db
    .prepare(
      `SELECT id, stage, home_team_id, away_team_id, status, home_score, away_score, home_pens, away_pens, walkover_winner,
              scorer_member_id, home_source, away_source
         FROM fixtures WHERE id = ? AND club_id = ?`,
    )
    .bind(fixtureId, ctx.club.id)
    .first<Record<string, unknown>>();
  if (!r) throw errors.notFound();
  return toFixture(r);
}

const toFixture = (r: Record<string, unknown>): FixtureRow => ({
  id: String(r.id),
  stage: String(r.stage),
  homeTeamId: (r.home_team_id ?? null) as string | null,
  awayTeamId: (r.away_team_id ?? null) as string | null,
  status: String(r.status),
  homeScore: (r.home_score ?? null) as number | null,
  awayScore: (r.away_score ?? null) as number | null,
  homePens: (r.home_pens ?? null) as number | null,
  awayPens: (r.away_pens ?? null) as number | null,
  walkoverWinner: (r.walkover_winner ?? null) as string | null,
  scorer_member_id: (r.scorer_member_id ?? null) as string | null,
  home_source: (r.home_source ?? null) as string | null,
  away_source: (r.away_source ?? null) as string | null,
});

const isKnockout = (f: { stage: string }) => f.stage === "knockout" || f.stage === "third";

async function approvedTeamIds(ctx: CommandContext) {
  const { results } = await ctx.db
    .prepare("SELECT id FROM teams WHERE club_id = ? AND status = 'approved'")
    .bind(ctx.club.id)
    .all<{ id: string }>();
  return new Set(results.map((r) => r.id));
}

function requireOrganizer(ctx: CommandContext) {
  if (!isAdmin(ctx.member.role)) throw errors.forbidden();
}

// ----------------------------------------------------------------- calendario

/**
 * El calendario de una fase, como lo genera la app (spec 2.0 §7.4). El servidor comprueba que los
 * equipos estén aprobados, que las fuentes apunten a partidos del mismo envío y que la fase no
 * tenga ya partidos.
 */
export const generateFixtures = command(
  z
    .object({
      stage: z.enum(["league", "group", "knockout"]),
      fixtures: z.array(draftSchema).min(1).max(512),
      groups: z.array(z.object({ teamId: id, groupLabel: z.string().min(1).max(4) }).strict()).max(32).optional(),
    })
    .strict(),
  async (ctx, p) => {
    requireOrganizer(ctx);
    const t = await loadTournament(ctx);
    assertNotFinished(t);
    const family: readonly string[] = FAMILY[p.stage];
    const existing = await ctx.db
      .prepare(`SELECT 1 FROM fixtures WHERE club_id = ? AND stage IN (${family.map(() => "?").join(", ")}) LIMIT 1`)
      .bind(ctx.club.id, ...family)
      .first();
    if (existing) throw errors.invalidState("Esa fase ya tiene calendario: bórralo antes de generar otro");
    const approved = await approvedTeamIds(ctx);
    const ids = new Set(p.fixtures.map((f) => f.id));
    if (ids.size !== p.fixtures.length) throw errors.invalidInput({ fixtures: ["Partidos repetidos"] });
    for (const f of p.fixtures) {
      if (!family.includes(f.stage)) throw errors.invalidInput({ fixtures: ["Un partido no es de esta fase"] });
      for (const team of [f.homeTeamId, f.awayTeamId]) {
        if (team && !approved.has(team)) throw errors.invalidInput({ fixtures: ["Un equipo no está aprobado"] });
      }
      for (const s of [f.homeSource, f.awaySource]) {
        if (s?.winnerOf && s.loserOf) throw errors.invalidInput({ fixtures: ["Una fuente es ganador o perdedor, no los dos"] });
        const ref = s?.winnerOf ?? s?.loserOf;
        if (ref && !ids.has(ref)) throw errors.invalidInput({ fixtures: ["Una fuente apunta a un partido que no existe"] });
      }
      if (f.homeTeamId && f.homeTeamId === f.awayTeamId) throw errors.invalidInput({ fixtures: ["Un equipo contra sí mismo"] });
    }
    for (const g of p.groups ?? []) {
      if (!approved.has(g.teamId)) throw errors.invalidInput({ groups: ["Un equipo no está aprobado"] });
    }
    const at = ctx.now.toISOString();
    const statements: D1PreparedStatement[] = p.fixtures.map((f) =>
      ctx.db
        .prepare(
          `INSERT INTO fixtures (id, club_id, stage, round, group_label, leg, slot, home_team_id, away_team_id, home_source,
                                 away_source, starts_at, status, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'scheduled', ?, ?)`,
        )
        .bind(
          f.id,
          ctx.club.id,
          f.stage,
          f.round,
          f.groupLabel ?? null,
          f.leg,
          f.slot ?? null,
          f.homeTeamId ?? null,
          f.awayTeamId ?? null,
          f.homeSource ? JSON.stringify(f.homeSource) : null,
          f.awaySource ? JSON.stringify(f.awaySource) : null,
          f.startsAt ? new Date(f.startsAt).toISOString() : null,
          at,
          at,
        ),
    );
    const touched: Touch[] = [];
    for (const g of p.groups ?? []) {
      statements.push(
        ctx.db.prepare("UPDATE teams SET group_label = ?, updated_at = ? WHERE id = ? AND club_id = ?").bind(g.groupLabel, at, g.teamId, ctx.club.id),
      );
      touched.push(upsert("team", g.teamId));
    }
    // Una fila de `changes` por partido, calculada en SQL (no hace falta una por sentencia).
    statements.push(
      ctx.db
        .prepare(
          `INSERT INTO changes (club_id, entity, entity_key, op, at)
           SELECT club_id, 'fixture', id, 'upsert', ? FROM fixtures WHERE club_id = ? AND stage IN (${family.map(() => "?").join(", ")})`,
        )
        .bind(at, ctx.club.id, ...family),
    );
    return {
      statements,
      touched,
      audit: [{ action: "fixtures.generate", entity: "tournament", entityKey: ctx.club.id, summary: { stage: p.stage, n: p.fixtures.length } }],
    };
  },
);

/** Borra el calendario de una fase, si todavía no tiene ningún resultado. */
export const clearFixtures = command(z.object({ stage: z.enum(["league", "group", "knockout"]) }).strict(), async (ctx, p) => {
  requireOrganizer(ctx);
  const t = await loadTournament(ctx);
  assertNotFinished(t);
  const family: readonly string[] = FAMILY[p.stage];
  const marks = family.map(() => "?").join(", ");
  const decided = await ctx.db
    .prepare(`SELECT 1 FROM fixtures WHERE club_id = ? AND stage IN (${marks}) AND status IN ('played', 'walkover') LIMIT 1`)
    .bind(ctx.club.id, ...family)
    .first();
  if (decided) throw errors.invalidState("Ya hay resultados en esa fase: no se puede borrar");
  const at = ctx.now.toISOString();
  return {
    statements: [
      ctx.db
        .prepare(
          `INSERT INTO changes (club_id, entity, entity_key, op, at)
           SELECT club_id, 'fixture', id, 'delete', ? FROM fixtures WHERE club_id = ? AND stage IN (${marks})`,
        )
        .bind(at, ctx.club.id, ...family),
      ctx.db.prepare(`DELETE FROM fixtures WHERE club_id = ? AND stage IN (${marks})`).bind(ctx.club.id, ...family),
    ],
    touched: [],
    audit: [{ action: "fixtures.clear", entity: "tournament", entityKey: ctx.club.id, summary: { stage: p.stage } }],
  };
});

/** Fecha, terreno y anotador de un partido. */
export const scheduleFixture = command(
  z
    .object({
      fixtureId: id,
      startsAt: z.iso.datetime({ offset: true }).nullable().optional(),
      place: z.string().trim().max(60).nullable().optional(),
      scorerMemberId: id.nullable().optional(),
    })
    .strict(),
  async (ctx, p) => {
    requireOrganizer(ctx);
    assertNotFinished(await loadTournament(ctx));
    const f = await findFixture(ctx, p.fixtureId);
    if (p.scorerMemberId) {
      const m = await ctx.db
        .prepare("SELECT 1 FROM members WHERE id = ? AND club_id = ? AND status = 'active' AND user_id IS NOT NULL")
        .bind(p.scorerMemberId, ctx.club.id)
        .first();
      if (!m) throw errors.invalidInput({ scorerMemberId: ["Tiene que ser miembro del torneo, con cuenta"] });
    }
    const sets: string[] = [];
    const binds: unknown[] = [];
    if (p.startsAt !== undefined) {
      sets.push("starts_at = ?");
      binds.push(p.startsAt === null ? null : new Date(p.startsAt).toISOString());
    }
    if (p.place !== undefined) {
      sets.push("place = ?");
      binds.push(p.place || null);
    }
    if (p.scorerMemberId !== undefined) {
      sets.push("scorer_member_id = ?");
      binds.push(p.scorerMemberId);
    }
    if (sets.length === 0) throw errors.invalidInput({ fixtureId: ["No hay nada que cambiar"] });
    return {
      statements: [
        ctx.db.prepare(`UPDATE fixtures SET ${sets.join(", ")}, updated_at = ? WHERE id = ?`).bind(...binds, ctx.now.toISOString(), f.id),
      ],
      touched: [upsert("fixture", f.id)],
    };
  },
);

// ---------------------------------------------------------------- resultados

/** Los partidos que esperan al ganador (o perdedor) de [f]: qué equipo les toca ahora. */
async function dependentUpdates(ctx: CommandContext, f: FixtureRow, after: KnockoutFixture) {
  if (!isKnockout(f)) return [];
  const { results } = await ctx.db
    .prepare(
      `SELECT id, status, home_source, away_source, home_team_id, away_team_id FROM fixtures
        WHERE club_id = ? AND (home_source LIKE ?2 OR away_source LIKE ?2)`,
    )
    .bind(ctx.club.id, `%"${f.id}"%`)
    .all<{ id: string; status: string; home_source: string | null; away_source: string | null; home_team_id: string | null; away_team_id: string | null }>();
  const winner = winnerOf(after);
  const loser = loserOf(after);
  const updates: { fixtureId: string; column: "home_team_id" | "away_team_id"; teamId: string | null }[] = [];
  for (const d of results) {
    for (const [column, raw, current] of [
      ["home_team_id", d.home_source, d.home_team_id],
      ["away_team_id", d.away_source, d.away_team_id],
    ] as const) {
      if (!raw) continue;
      const s = JSON.parse(raw) as { winnerOf?: string; loserOf?: string };
      const team = s.winnerOf === f.id ? winner : s.loserOf === f.id ? loser : undefined;
      if (team === undefined || team === current) continue;
      if (d.status === "played" || d.status === "walkover") {
        throw errors.invalidState("Ya se jugó el partido siguiente: corrígelo antes");
      }
      updates.push({ fixtureId: d.id, column, teamId: team });
    }
  }
  return updates;
}

function applyDependents(ctx: CommandContext, updates: Awaited<ReturnType<typeof dependentUpdates>>) {
  return {
    statements: updates.map((u) =>
      ctx.db.prepare(`UPDATE fixtures SET ${u.column} = ?, updated_at = ? WHERE id = ?`).bind(u.teamId, ctx.now.toISOString(), u.fixtureId),
    ),
    touched: updates.map((u) => upsert("fixture", u.fixtureId)),
  };
}

/** Borra eventos y alineación de un partido, con sus cambios para el pull. */
function clearDetail(ctx: CommandContext, fixtureId: string) {
  const at = ctx.now.toISOString();
  return [
    ctx.db
      .prepare(
        `INSERT INTO changes (club_id, entity, entity_key, op, at)
         SELECT club_id, 'fixtureEvent', id, 'delete', ? FROM fixture_events WHERE fixture_id = ?`,
      )
      .bind(at, fixtureId),
    ctx.db
      .prepare(
        `INSERT INTO changes (club_id, entity, entity_key, op, at)
         SELECT club_id, 'fixtureLineup', id, 'delete', ? FROM fixture_lineups WHERE fixture_id = ?`,
      )
      .bind(at, fixtureId),
    ctx.db.prepare("DELETE FROM fixture_events WHERE fixture_id = ?").bind(fixtureId),
    ctx.db.prepare("DELETE FROM fixture_lineups WHERE fixture_id = ?").bind(fixtureId),
  ];
}

const eventSchema = z
  .object({
    id: z.uuid(),
    teamId: id,
    memberId: id,
    kind: z.enum(["goal", "own_goal", "yellow", "red", "mvp"]),
    assistMemberId: id.nullable().optional(),
    minute: z.number().int().min(0).max(200).nullable().optional(),
  })
  .strict();

const score = z.number().int().min(0).max(99);

/**
 * El resultado de un partido con su detalle (spec 2.0 §7.3). Lo pone el anotador del partido o el
 * staff. Reemplaza los eventos y la alineación. Si trae goles, suman el marcador (un autogol cuenta
 * para el rival). En eliminatoria, un empate necesita penales distintos; el ganador pasa solo al
 * partido siguiente.
 */
export const fixtureResult = command(
  z
    .object({
      fixtureId: id,
      homeScore: score,
      awayScore: score,
      homePens: score.nullable().optional(),
      awayPens: score.nullable().optional(),
      events: z.array(eventSchema).max(100).default([]),
      lineups: z.object({ home: z.array(id).max(40), away: z.array(id).max(40) }).strict().default({ home: [], away: [] }),
    })
    .strict(),
  async (ctx, p) => {
    const t = await loadTournament(ctx);
    if (t.status !== "in_progress") throw errors.invalidState("Los resultados se ponen con el torneo en juego");
    const f = await findFixture(ctx, p.fixtureId);
    if (!isStaff(ctx.member.role) && f.scorer_member_id !== ctx.member.id) throw errors.forbidden();
    if (!f.homeTeamId || !f.awayTeamId) throw errors.invalidState("Todavía no se sabe quién juega");
    if (f.status === "cancelled") throw errors.invalidState("El partido está cancelado");
    const home = f.homeTeamId;
    const away = f.awayTeamId;

    const { results: roster } = await ctx.db
      .prepare("SELECT team_id, member_id FROM team_players WHERE team_id IN (?, ?) AND status = 'active'")
      .bind(home, away)
      .all<{ team_id: string; member_id: string }>();
    const inTeam = (team: string, member: string) => roster.some((r) => r.team_id === team && r.member_id === member);
    const bad = (field: string, msg: string) => errors.invalidInput({ [field]: [msg] });
    for (const m of p.lineups.home) if (!inTeam(home, m)) throw bad("lineups", "Hay alguien que no es de la plantilla");
    for (const m of p.lineups.away) if (!inTeam(away, m)) throw bad("lineups", "Hay alguien que no es de la plantilla");
    let homeGoals = 0;
    let awayGoals = 0;
    let anyGoal = false;
    let mvps = 0;
    for (const e of p.events) {
      if (e.teamId !== home && e.teamId !== away) throw bad("events", "Un evento es de otro equipo");
      if (!inTeam(e.teamId, e.memberId)) throw bad("events", "Hay alguien que no es de la plantilla");
      if (e.assistMemberId) {
        if (e.kind !== "goal" || e.assistMemberId === e.memberId || !inTeam(e.teamId, e.assistMemberId)) {
          throw bad("events", "Una asistencia no cuadra");
        }
      }
      if (e.kind === "goal" || e.kind === "own_goal") {
        anyGoal = true;
        const forHome = e.kind === "goal" ? e.teamId === home : e.teamId === away;
        if (forHome) homeGoals++;
        else awayGoals++;
      }
      if (e.kind === "mvp") mvps++;
    }
    if (mvps > 1) throw bad("events", "Un solo MVP por partido");
    if (anyGoal && (homeGoals !== p.homeScore || awayGoals !== p.awayScore)) {
      throw bad("events", "Los goles no suman el marcador");
    }
    const pens = p.homePens !== undefined && p.homePens !== null && p.awayPens !== undefined && p.awayPens !== null;
    if (isKnockout(f) && p.homeScore === p.awayScore && (!pens || p.homePens === p.awayPens)) {
      throw bad("homePens", "En eliminatoria, un empate se decide por penales");
    }
    if (pens && (!isKnockout(f) || p.homeScore !== p.awayScore)) throw bad("homePens", "Penales solo si empatan en eliminatoria");

    const after: KnockoutFixture = {
      ...f,
      status: "played",
      homeScore: p.homeScore,
      awayScore: p.awayScore,
      homePens: pens ? p.homePens! : null,
      awayPens: pens ? p.awayPens! : null,
      walkoverWinner: null,
    };
    const dependents = applyDependents(ctx, await dependentUpdates(ctx, f, after));
    const at = ctx.now.toISOString();
    const statements: D1PreparedStatement[] = [
      ctx.db
        .prepare(
          `UPDATE fixtures SET status = 'played', home_score = ?, away_score = ?, home_pens = ?, away_pens = ?, walkover_winner = NULL,
                  result_by = ?, result_at = ?, updated_at = ? WHERE id = ?`,
        )
        .bind(p.homeScore, p.awayScore, after.homePens, after.awayPens, ctx.member.id, at, at, f.id),
      ...clearDetail(ctx, f.id),
    ];
    const touched: Touch[] = [upsert("fixture", f.id)];
    for (const e of p.events) {
      statements.push(
        ctx.db
          .prepare(
            `INSERT INTO fixture_events (id, club_id, fixture_id, team_id, member_id, kind, assist_member_id, minute, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(e.id, ctx.club.id, f.id, e.teamId, e.memberId, e.kind, e.assistMemberId ?? null, e.minute ?? null, at),
      );
      touched.push(upsert("fixtureEvent", e.id));
    }
    for (const [team, members] of [
      [home, p.lineups.home],
      [away, p.lineups.away],
    ] as const) {
      for (const m of new Set(members)) {
        const key = `${f.id}:${m}`;
        statements.push(
          ctx.db
            .prepare("INSERT INTO fixture_lineups (id, club_id, fixture_id, team_id, member_id) VALUES (?, ?, ?, ?, ?)")
            .bind(key, ctx.club.id, f.id, team, m),
        );
        touched.push(upsert("fixtureLineup", key));
      }
    }
    statements.push(...dependents.statements);
    touched.push(...dependents.touched);
    return {
      statements,
      touched,
      audit: [{ action: "fixture.result", entity: "fixture", entityKey: f.id, summary: { score: `${p.homeScore}-${p.awayScore}` } }],
    };
  },
);

/**
 * Cancelar, dar por ganado sin jugar (walkover) o devolver a "por jugar" (borra el resultado). Los
 * partidos que dependen de este se ponen al día.
 */
export const setFixtureStatus = command(
  z.object({ fixtureId: id, status: z.enum(["scheduled", "cancelled", "walkover"]), walkoverWinner: id.optional() }).strict(),
  async (ctx, p) => {
    requireOrganizer(ctx);
    const t = await loadTournament(ctx);
    assertNotFinished(t);
    const f = await findFixture(ctx, p.fixtureId);
    if (p.status === "walkover") {
      // Como un resultado: con el torneo en juego y los dos equipos conocidos.
      if (t.status !== "in_progress") throw errors.invalidState("Los resultados se ponen con el torneo en juego");
      if (!f.homeTeamId || !f.awayTeamId) throw errors.invalidState("Todavía no se sabe quién juega");
      if (p.walkoverWinner !== f.homeTeamId && p.walkoverWinner !== f.awayTeamId) {
        throw errors.invalidInput({ walkoverWinner: ["Tiene que ser uno de los dos equipos"] });
      }
    }
    const after: KnockoutFixture = {
      ...f,
      status: p.status,
      homeScore: null,
      awayScore: null,
      homePens: null,
      awayPens: null,
      walkoverWinner: p.status === "walkover" ? p.walkoverWinner! : null,
    };
    const dependents = applyDependents(ctx, await dependentUpdates(ctx, f, after));
    const at = ctx.now.toISOString();
    return {
      statements: [
        ctx.db
          .prepare(
            `UPDATE fixtures SET status = ?, home_score = NULL, away_score = NULL, home_pens = NULL, away_pens = NULL,
                    walkover_winner = ?, result_by = ?, result_at = ?, updated_at = ? WHERE id = ?`,
          )
          .bind(p.status, after.walkoverWinner, p.status === "walkover" ? ctx.member.id : null, p.status === "walkover" ? at : null, at, f.id),
        ...clearDetail(ctx, f.id),
        ...dependents.statements,
      ],
      touched: [upsert("fixture", f.id), ...dependents.touched],
      audit: [{ action: "fixture.setStatus", entity: "fixture", entityKey: f.id, summary: p }],
    };
  },
);

/** De los grupos al cuadro: los organizadores ponen los equipos en los partidos de eliminatoria. */
export const advanceStage = command(
  z
    .object({
      assignments: z
        .array(z.object({ fixtureId: id, homeTeamId: id.optional(), awayTeamId: id.optional() }).strict())
        .min(1)
        .max(32),
    })
    .strict(),
  async (ctx, p) => {
    requireOrganizer(ctx);
    assertNotFinished(await loadTournament(ctx));
    const approved = await approvedTeamIds(ctx);
    const ids = p.assignments.map((a) => a.fixtureId);
    const { results } = await ctx.db
      .prepare(
        `SELECT id, stage, status, home_team_id, away_team_id, home_source, away_source FROM fixtures
          WHERE club_id = ? AND id IN (${ids.map(() => "?").join(", ")})`,
      )
      .bind(ctx.club.id, ...ids)
      .all<{
        id: string;
        stage: string;
        status: string;
        home_team_id: string | null;
        away_team_id: string | null;
        home_source: string | null;
        away_source: string | null;
      }>();
    // Solo se ponen equipos en huecos que salen de un grupo (o sin fuente), no en los de "ganador de".
    const fromGroup = (raw: string | null) => {
      if (!raw) return true;
      const s = JSON.parse(raw) as { group?: string };
      return s.group !== undefined;
    };
    const byId = new Map(results.map((r) => [r.id, r]));
    const statements: D1PreparedStatement[] = [];
    const touched: Touch[] = [];
    for (const a of p.assignments) {
      const f = byId.get(a.fixtureId);
      if (!f || !isKnockout(f)) throw errors.invalidInput({ assignments: ["Solo partidos de eliminatoria"] });
      if (f.status === "played" || f.status === "walkover") throw errors.invalidState("Ese partido ya se jugó");
      for (const team of [a.homeTeamId, a.awayTeamId]) {
        if (team && !approved.has(team)) throw errors.invalidInput({ assignments: ["Un equipo no está aprobado"] });
      }
      if ((a.homeTeamId && !fromGroup(f.home_source)) || (a.awayTeamId && !fromGroup(f.away_source))) {
        throw errors.invalidInput({ assignments: ["Ese hueco lo decide otro partido"] });
      }
      const home = a.homeTeamId ?? f.home_team_id;
      const away = a.awayTeamId ?? f.away_team_id;
      if (home && home === away) throw errors.invalidInput({ assignments: ["Un equipo contra sí mismo"] });
      const sets: string[] = [];
      const binds: unknown[] = [];
      if (a.homeTeamId) {
        sets.push("home_team_id = ?");
        binds.push(a.homeTeamId);
      }
      if (a.awayTeamId) {
        sets.push("away_team_id = ?");
        binds.push(a.awayTeamId);
      }
      if (sets.length === 0) continue;
      statements.push(
        ctx.db.prepare(`UPDATE fixtures SET ${sets.join(", ")}, updated_at = ? WHERE id = ?`).bind(...binds, ctx.now.toISOString(), f.id),
      );
      touched.push(upsert("fixture", f.id));
    }
    return { statements, touched, audit: [{ action: "stage.advance", entity: "tournament", entityKey: ctx.club.id, summary: { n: touched.length } }] };
  },
);

