import { z } from "zod";
import { isAdmin } from "../authz";
import { errors } from "../http/errors";
import {
  canAdvance,
  registrationOpen,
  rostersOpen,
  rulesOf,
  rulesSchema,
  type TournamentRules,
  type TournamentStatus,
} from "../rules/tournament";
import { upsert, type Touch } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { key } from "./pachanga";

const id = z.string().min(1).max(64);

export type TournamentRow = {
  format: string;
  status: TournamentStatus;
  rules: TournamentRules;
  registrationClosesAt: string | null;
  maxTeams: number;
  minPlayers: number;
  maxPlayers: number;
};

export async function loadTournament(ctx: CommandContext): Promise<TournamentRow> {
  const row = await ctx.db
    .prepare(
      "SELECT format, status, rules, registration_closes_at, max_teams, min_players, max_players FROM tournaments WHERE club_id = ?",
    )
    .bind(ctx.club.id)
    .first<{
      format: string;
      status: TournamentStatus;
      rules: string;
      registration_closes_at: string | null;
      max_teams: number;
      min_players: number;
      max_players: number;
    }>();
  if (!row) throw errors.notFound();
  return {
    format: row.format,
    status: row.status,
    rules: rulesOf(row.rules),
    registrationClosesAt: row.registration_closes_at,
    maxTeams: row.max_teams,
    minPlayers: row.min_players,
    maxPlayers: row.max_players,
  };
}

/** Un torneo terminado no acepta cambios (se reabre con `tournament.reopen`). */
export function assertNotFinished(t: TournamentRow) {
  if (t.status === "finished") throw errors.tournamentClosed();
}

type TeamRow = { id: string; status: string; captain_member_id: string | null };

export async function findTeam(ctx: CommandContext, teamId: string) {
  const row = await ctx.db
    .prepare("SELECT id, status, captain_member_id FROM teams WHERE id = ? AND club_id = ?")
    .bind(teamId, ctx.club.id)
    .first<TeamRow>();
  if (!row) throw errors.notFound();
  return row;
}

const isCaptain = (ctx: CommandContext, team: TeamRow) => team.captain_member_id === ctx.member.id;

async function approvedTeams(ctx: CommandContext) {
  const row = await ctx.db
    .prepare("SELECT COUNT(*) AS n FROM teams WHERE club_id = ? AND status = 'approved'")
    .bind(ctx.club.id)
    .first<{ n: number }>();
  return row!.n;
}

/** El miembro no está en ningún equipo activo de este torneo (salvo, si se dice, en `except`). */
async function assertFree(ctx: CommandContext, memberId: string, except?: string) {
  const row = await ctx.db
    .prepare("SELECT team_id FROM team_players WHERE club_id = ? AND member_id = ? AND status = 'active'")
    .bind(ctx.club.id, memberId)
    .first<{ team_id: string }>();
  if (row && row.team_id !== except) throw errors.alreadyInTeam();
}

async function assertMember(ctx: CommandContext, memberId: string) {
  const row = await ctx.db
    .prepare("SELECT user_id FROM members WHERE id = ? AND club_id = ? AND status = 'active'")
    .bind(memberId, ctx.club.id)
    .first<{ user_id: string | null }>();
  if (!row) throw errors.invalidInput({ memberId: ["No es miembro activo de este torneo"] });
  return row;
}

/** Para "representa a un servidor": el capitán (con cuenta) tiene que ser miembro activo de él. */
async function assertRepresents(ctx: CommandContext, captainUserId: string | null, clubId: string) {
  if (!captainUserId) throw errors.invalidInput({ representsClubId: ["El capitán tiene que tener cuenta"] });
  const row = await ctx.db
    .prepare(
      `SELECT 1 FROM members m JOIN clubs c ON c.id = m.club_id
        WHERE m.club_id = ? AND m.user_id = ? AND m.status = 'active' AND c.status = 'active' AND c.kind = 'group'`,
    )
    .bind(clubId, captainUserId)
    .first();
  if (!row) throw errors.invalidInput({ representsClubId: ["El capitán no es miembro de ese servidor"] });
}

async function activePlayers(ctx: CommandContext, teamId: string) {
  const row = await ctx.db
    .prepare("SELECT COUNT(*) AS n FROM team_players WHERE team_id = ? AND status = 'active'")
    .bind(teamId)
    .first<{ n: number }>();
  return row!.n;
}

const playerKey = (teamId: string, memberId: string) => key(teamId, memberId);

function addPlayerStatement(ctx: CommandContext, teamId: string, memberId: string, shirt: number | null) {
  return ctx.db
    .prepare(
      `INSERT INTO team_players (id, club_id, team_id, member_id, shirt, status, updated_at) VALUES (?, ?, ?, ?, ?, 'active', ?)
       ON CONFLICT (id) DO UPDATE SET status = 'active', shirt = COALESCE(excluded.shirt, team_players.shirt), updated_at = excluded.updated_at`,
    )
    .bind(playerKey(teamId, memberId), ctx.club.id, teamId, memberId, shirt, ctx.now.toISOString());
}

const nameSchema = z.string().trim().min(2, { error: "Mínimo 2 caracteres" }).max(30, { error: "Máximo 30 caracteres" });
const shortSchema = z
  .string()
  .trim()
  .toUpperCase()
  .regex(/^[A-Z0-9ÁÉÍÓÚÑ]{2,4}$/, { error: "De 2 a 4 letras" });
const colorSchema = z.number().int().min(0).max(7);

// ------------------------------------------------------------------ torneo

export const updateTournament = command(
  z
    .object({
      format: z.enum(["league", "cup", "groups_cup"]).optional(),
      rules: rulesSchema.partial().strict().optional(),
      registrationClosesAt: z.iso.datetime({ offset: true }).nullable().optional(),
      startsOn: z.iso.date().nullable().optional(),
      maxTeams: z.number().int().min(2).max(32).optional(),
      minPlayers: z.number().int().min(1).max(30).optional(),
      maxPlayers: z.number().int().min(1).max(30).optional(),
      status: z.enum(["registration", "in_progress"]).optional(),
    })
    .strict()
    .refine((p) => Object.keys(p).length > 0, { error: "No hay nada que cambiar" }),
  async (ctx, p) => {
    if (!isAdmin(ctx.member.role)) throw errors.forbidden();
    const t = await loadTournament(ctx);
    assertNotFinished(t);
    if (p.status && !canAdvance(t.status, p.status)) throw errors.invalidState("El torneo ya está en esa fase o más adelante");
    if (p.status === "in_progress" && (await approvedTeams(ctx)) < 2) {
      throw errors.invalidState("Hacen falta al menos 2 equipos aprobados para empezar");
    }
    if (p.format && p.format !== t.format) {
      const fixtures = await ctx.db
        .prepare("SELECT 1 FROM fixtures WHERE club_id = ? LIMIT 1")
        .bind(ctx.club.id)
        .first();
      if (fixtures) throw errors.invalidState("Ya hay calendario: bórralo antes de cambiar el formato");
    }
    const min = p.minPlayers ?? t.minPlayers;
    const max = p.maxPlayers ?? t.maxPlayers;
    if (min > max) throw errors.invalidInput({ minPlayers: ["No puede ser más que el máximo"] });
    if (p.maxTeams && p.maxTeams < (await approvedTeams(ctx))) {
      throw errors.invalidInput({ maxTeams: ["Ya hay más equipos aprobados"] });
    }
    if (p.maxPlayers) {
      const biggest = await ctx.db
        .prepare(
          `SELECT COALESCE(MAX(n), 0) AS n FROM (SELECT COUNT(*) AS n FROM team_players
            WHERE club_id = ? AND status = 'active' GROUP BY team_id)`,
        )
        .bind(ctx.club.id)
        .first<{ n: number }>();
      if (p.maxPlayers < biggest!.n) throw errors.invalidInput({ maxPlayers: ["Ya hay plantillas más grandes"] });
    }
    const rules = p.rules ? rulesSchema.parse({ ...t.rules, ...p.rules }) : null;

    const sets: string[] = [];
    const binds: unknown[] = [];
    const set = (column: string, value: unknown) => {
      sets.push(`${column} = ?`);
      binds.push(value);
    };
    if (p.format) set("format", p.format);
    if (rules) set("rules", JSON.stringify(rules));
    // En UTC, como todas las fechas: se comparan como texto.
    if (p.registrationClosesAt !== undefined) {
      set("registration_closes_at", p.registrationClosesAt === null ? null : new Date(p.registrationClosesAt).toISOString());
    }
    if (p.startsOn !== undefined) set("starts_on", p.startsOn);
    if (p.maxTeams) set("max_teams", p.maxTeams);
    if (p.minPlayers) set("min_players", p.minPlayers);
    if (p.maxPlayers) set("max_players", p.maxPlayers);
    if (p.status) set("status", p.status);
    return {
      statements: [
        ctx.db
          .prepare(`UPDATE tournaments SET ${sets.join(", ")}, updated_at = ? WHERE club_id = ?`)
          .bind(...binds, ctx.now.toISOString(), ctx.club.id),
      ],
      touched: [upsert("tournament", ctx.club.id)],
      audit: [{ action: "tournament.update", entity: "tournament", entityKey: ctx.club.id, summary: p }],
    };
  },
);

// ------------------------------------------------------------------ equipos

/**
 * Inscribir un equipo. Un organizador lo crea aprobado (con capitán o sin él); cualquier miembro
 * con cuenta, durante la inscripción, lo crea pendiente con él de capitán.
 */
export const createTeam = command(
  z
    .object({
      id: z.uuid(),
      name: nameSchema,
      shortName: shortSchema,
      color: colorSchema.default(0),
      captainMemberId: id.nullable().optional(),
      representsClubId: id.nullable().optional(),
    })
    .strict(),
  async (ctx, p) => {
    const t = await loadTournament(ctx);
    assertNotFinished(t);
    const organizer = isAdmin(ctx.member.role);
    if (!organizer && !registrationOpen(t.status, t.registrationClosesAt, ctx.clientAt)) throw errors.registrationClosed();
    if (!organizer && ctx.member.role === "guest") throw errors.forbidden();
    const captain = organizer ? (p.captainMemberId ?? null) : ctx.member.id;
    let captainUser: string | null = null;
    if (captain) {
      captainUser = (await assertMember(ctx, captain)).user_id;
      await assertFree(ctx, captain);
    }
    if (p.representsClubId) await assertRepresents(ctx, captainUser, p.representsClubId);
    const status = organizer ? "approved" : "pending";
    if (status === "approved" && (await approvedTeams(ctx)) >= t.maxTeams) throw errors.tournamentFull();
    const at = ctx.now.toISOString();
    const statements = [
      ctx.db
        .prepare(
          `INSERT INTO teams (id, club_id, name, short_name, color, captain_member_id, represents_club_id, status, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(p.id, ctx.club.id, p.name, p.shortName, p.color, captain, p.representsClubId ?? null, status, at, at),
    ];
    const touched: Touch[] = [upsert("team", p.id)];
    if (captain) {
      statements.push(addPlayerStatement(ctx, p.id, captain, null));
      touched.push(upsert("teamPlayer", playerKey(p.id, captain)));
    }
    return {
      statements,
      touched,
      audit: [{ action: "team.create", entity: "team", entityKey: p.id, summary: { name: p.name, status } }],
    };
  },
);

export const updateTeam = command(
  z
    .object({
      teamId: id,
      name: nameSchema.optional(),
      shortName: shortSchema.optional(),
      color: colorSchema.optional(),
      captainMemberId: id.optional(),
      representsClubId: id.nullable().optional(),
    })
    .strict()
    .refine((p) => Object.keys(p).length > 1, { error: "No hay nada que cambiar" }),
  async (ctx, p) => {
    const t = await loadTournament(ctx);
    assertNotFinished(t);
    const team = await findTeam(ctx, p.teamId);
    if (!isAdmin(ctx.member.role) && !isCaptain(ctx, team)) throw errors.forbidden();
    const captain = p.captainMemberId ?? team.captain_member_id;
    if (p.captainMemberId) {
      const inTeam = await ctx.db
        .prepare("SELECT 1 FROM team_players WHERE id = ? AND status = 'active'")
        .bind(playerKey(team.id, p.captainMemberId))
        .first();
      if (!inTeam) throw errors.invalidInput({ captainMemberId: ["El capitán tiene que estar en la plantilla"] });
    }
    if (p.representsClubId) {
      const captainUser = captain ? (await assertMember(ctx, captain)).user_id : null;
      await assertRepresents(ctx, captainUser, p.representsClubId);
    }
    const sets: string[] = [];
    const binds: unknown[] = [];
    const set = (column: string, value: unknown) => {
      sets.push(`${column} = ?`);
      binds.push(value);
    };
    if (p.name) set("name", p.name);
    if (p.shortName) set("short_name", p.shortName);
    if (p.color !== undefined) set("color", p.color);
    if (p.captainMemberId) set("captain_member_id", p.captainMemberId);
    if (p.representsClubId !== undefined) set("represents_club_id", p.representsClubId);
    return {
      statements: [
        ctx.db
          .prepare(`UPDATE teams SET ${sets.join(", ")}, updated_at = ? WHERE id = ?`)
          .bind(...binds, ctx.now.toISOString(), team.id),
      ],
      touched: [upsert("team", team.id)],
      audit: [{ action: "team.update", entity: "team", entityKey: team.id, summary: p }],
    };
  },
);

/**
 * Aprobar, dejar pendiente o retirar un equipo (organizadores). El capitán solo puede retirar el
 * suyo mientras no haya empezado el torneo. Al retirarlo, su plantilla queda libre.
 */
export const setTeamStatus = command(
  z.object({ teamId: id, status: z.enum(["pending", "approved", "withdrawn"]) }).strict(),
  async (ctx, p) => {
    const t = await loadTournament(ctx);
    assertNotFinished(t);
    const team = await findTeam(ctx, p.teamId);
    const organizer = isAdmin(ctx.member.role);
    if (!organizer && !(isCaptain(ctx, team) && p.status === "withdrawn" && rostersOpen(t.status))) {
      throw errors.forbidden();
    }
    if (team.status === "withdrawn" && p.status !== "withdrawn") {
      throw errors.invalidState("Un equipo retirado no vuelve: que se inscriba otra vez");
    }
    if (p.status === "approved" && team.status !== "approved" && (await approvedTeams(ctx)) >= t.maxTeams) {
      throw errors.tournamentFull();
    }
    const at = ctx.now.toISOString();
    const statements = [
      ctx.db.prepare("UPDATE teams SET status = ?, updated_at = ? WHERE id = ?").bind(p.status, at, team.id),
    ];
    if (p.status === "withdrawn") {
      statements.push(
        ctx.db
          .prepare(
            `INSERT INTO changes (club_id, entity, entity_key, op, at)
             SELECT club_id, 'teamPlayer', id, 'upsert', ? FROM team_players WHERE team_id = ? AND status = 'active'`,
          )
          .bind(at, team.id),
        ctx.db
          .prepare("UPDATE team_players SET status = 'removed', updated_at = ? WHERE team_id = ? AND status = 'active'")
          .bind(at, team.id),
      );
    }
    return {
      statements,
      touched: [upsert("team", team.id)],
      audit: [{ action: "team.setStatus", entity: "team", entityKey: team.id, summary: { status: p.status } }],
    };
  },
);

/** Plantillas: el capitán mientras no empiece el torneo; los organizadores, siempre. */
async function assertRosterAccess(ctx: CommandContext, team: TeamRow, t: TournamentRow) {
  assertNotFinished(t);
  if (team.status === "withdrawn") throw errors.invalidState("El equipo se retiró");
  if (isAdmin(ctx.member.role)) return;
  if (isCaptain(ctx, team) && rostersOpen(t.status)) return;
  throw errors.forbidden();
}

export const addPlayer = command(
  z.object({ teamId: id, memberId: id, shirt: z.number().int().min(0).max(99).nullable().optional() }).strict(),
  async (ctx, p) => {
    const t = await loadTournament(ctx);
    const team = await findTeam(ctx, p.teamId);
    await assertRosterAccess(ctx, team, t);
    await assertMember(ctx, p.memberId);
    await assertFree(ctx, p.memberId, team.id);
    const already = await ctx.db
      .prepare("SELECT 1 FROM team_players WHERE id = ? AND status = 'active'")
      .bind(playerKey(team.id, p.memberId))
      .first();
    if (!already && (await activePlayers(ctx, team.id)) >= t.maxPlayers) throw errors.teamFull();
    return {
      statements: [addPlayerStatement(ctx, team.id, p.memberId, p.shirt ?? null)],
      touched: [upsert("teamPlayer", playerKey(team.id, p.memberId))],
    };
  },
);

export const removePlayer = command(z.object({ teamId: id, memberId: id }).strict(), async (ctx, p) => {
  const t = await loadTournament(ctx);
  const team = await findTeam(ctx, p.teamId);
  await assertRosterAccess(ctx, team, t);
  if (team.captain_member_id === p.memberId) throw errors.invalidState("Es el capitán: nombra a otro antes de sacarlo");
  return {
    statements: [
      ctx.db
        .prepare("UPDATE team_players SET status = 'removed', updated_at = ? WHERE id = ?")
        .bind(ctx.now.toISOString(), playerKey(team.id, p.memberId)),
    ],
    touched: [upsert("teamPlayer", playerKey(team.id, p.memberId))],
  };
});

/** Salirse uno mismo de un equipo (mientras no empiece el torneo). El capitán no. */
export const leaveTeam = command(z.object({ teamId: id }).strict(), async (ctx, p) => {
  const t = await loadTournament(ctx);
  assertNotFinished(t);
  const team = await findTeam(ctx, p.teamId);
  if (!rostersOpen(t.status)) throw errors.invalidState("El torneo ya empezó: habla con el organizador");
  if (isCaptain(ctx, team)) throw errors.invalidState("Eres el capitán: nombra a otro antes de salirte");
  return {
    statements: [
      ctx.db
        .prepare("UPDATE team_players SET status = 'removed', updated_at = ? WHERE id = ? AND status = 'active'")
        .bind(ctx.now.toISOString(), playerKey(team.id, ctx.member.id)),
    ],
    touched: [upsert("teamPlayer", playerKey(team.id, ctx.member.id))],
  };
});

export const setShirt = command(
  z.object({ teamId: id, memberId: id, shirt: z.number().int().min(0).max(99).nullable() }).strict(),
  async (ctx, p) => {
    const t = await loadTournament(ctx);
    assertNotFinished(t);
    const team = await findTeam(ctx, p.teamId);
    // El organizador siempre; el capitán (o el propio jugador) mientras no empiece el torneo.
    const own = isCaptain(ctx, team) || ctx.member.id === p.memberId;
    if (!isAdmin(ctx.member.role) && !(own && rostersOpen(t.status))) throw errors.forbidden();
    return {
      statements: [
        ctx.db
          .prepare("UPDATE team_players SET shirt = ?, updated_at = ? WHERE id = ? AND status = 'active'")
          .bind(p.shirt, ctx.now.toISOString(), playerKey(team.id, p.memberId)),
      ],
      touched: [upsert("teamPlayer", playerKey(team.id, p.memberId))],
    };
  },
);

// ------------------------------------------------------------- final

const TEAM_AWARDS = new Set(["champion", "runner_up", "third", "fair_play"]);
const awardSchema = z
  .object({
    kind: z.enum(["champion", "runner_up", "third", "top_scorer", "top_assists", "best_player", "fair_play"]),
    teamId: id.nullable().optional(),
    memberId: id.nullable().optional(),
    value: z.number().int().min(0).max(999).nullable().optional(),
  })
  .strict();

/** Borra los premios del torneo, con sus cambios para el pull. */
function clearAwards(ctx: CommandContext) {
  return [
    ctx.db
      .prepare(
        `INSERT INTO changes (club_id, entity, entity_key, op, at)
         SELECT club_id, 'award', id, 'delete', ? FROM awards WHERE club_id = ?`,
      )
      .bind(ctx.now.toISOString(), ctx.club.id),
    ctx.db.prepare("DELETE FROM awards WHERE club_id = ?").bind(ctx.club.id),
  ];
}

/**
 * Terminar el torneo con sus premios (spec 2.0 §7.6): los propone la app y el organizador los
 * confirma. Uno de cada tipo; los de equipo, a un equipo aprobado; los de jugador, a un miembro.
 * Terminado, el torneo ya no acepta cambios (salvo `tournament.reopen`).
 */
export const finishTournament = command(
  z.object({ awards: z.array(awardSchema).max(7) }).strict(),
  async (ctx, p) => {
    if (!isAdmin(ctx.member.role)) throw errors.forbidden();
    const t = await loadTournament(ctx);
    if (t.status !== "in_progress") throw errors.invalidState("Solo se termina un torneo en juego");
    const kinds = new Set(p.awards.map((a) => a.kind));
    if (kinds.size !== p.awards.length) throw errors.invalidInput({ awards: ["Un premio de cada tipo"] });
    const { results: teams } = await ctx.db
      .prepare("SELECT id FROM teams WHERE club_id = ? AND status = 'approved'")
      .bind(ctx.club.id)
      .all<{ id: string }>();
    const approved = new Set(teams.map((r) => r.id));
    const memberIds = p.awards.map((a) => a.memberId).filter((m): m is string => !!m);
    const { results: members } = memberIds.length
      ? await ctx.db
          .prepare(`SELECT id FROM members WHERE club_id = ? AND id IN (${memberIds.map(() => "?").join(", ")})`)
          .bind(ctx.club.id, ...memberIds)
          .all<{ id: string }>()
      : { results: [] };
    const known = new Set(members.map((r) => r.id));
    for (const a of p.awards) {
      if (TEAM_AWARDS.has(a.kind) ? !a.teamId || !approved.has(a.teamId) : !a.memberId || !known.has(a.memberId)) {
        throw errors.invalidInput({ awards: ["Un premio no cuadra con los equipos o jugadores del torneo"] });
      }
    }
    const at = ctx.now.toISOString();
    const statements = [
      ...clearAwards(ctx),
      ...p.awards.map((a) =>
        ctx.db
          .prepare("INSERT INTO awards (id, club_id, kind, team_id, member_id, value, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
          .bind(`${ctx.club.id}:${a.kind}`, ctx.club.id, a.kind, a.teamId ?? null, a.memberId ?? null, a.value ?? null, at),
      ),
      ctx.db.prepare("UPDATE tournaments SET status = 'finished', updated_at = ? WHERE club_id = ?").bind(at, ctx.club.id),
    ];
    return {
      statements,
      touched: [upsert("tournament", ctx.club.id), ...p.awards.map((a) => upsert("award", `${ctx.club.id}:${a.kind}`))],
      audit: [{ action: "tournament.finish", entity: "tournament", entityKey: ctx.club.id, summary: { awards: p.awards.length } }],
    };
  },
);

/** Reabrir un torneo terminado (para corregir algo): vuelve a "en juego" y se quitan los premios. */
export const reopenTournament = command(z.object({}).strict(), async (ctx) => {
  if (!isAdmin(ctx.member.role)) throw errors.forbidden();
  const t = await loadTournament(ctx);
  if (t.status !== "finished") throw errors.invalidState("El torneo no está terminado");
  return {
    statements: [
      ...clearAwards(ctx),
      ctx.db.prepare("UPDATE tournaments SET status = 'in_progress', updated_at = ? WHERE club_id = ?").bind(ctx.now.toISOString(), ctx.club.id),
    ],
    touched: [upsert("tournament", ctx.club.id)],
    audit: [{ action: "tournament.reopen", entity: "tournament", entityKey: ctx.club.id }],
  };
});
