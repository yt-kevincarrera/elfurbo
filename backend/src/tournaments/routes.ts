import { Hono } from "hono";
import { z } from "zod";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { isAdmin } from "../authz";
import { admitStatements } from "../clubs/admit";
import { DEFAULT_SETTINGS, findMemberByUser, requireMembership } from "../clubs/model";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import { registrationOpen, type TournamentStatus } from "../rules/tournament";
import { changeStatement, upsert } from "../sync/changes";
import type { AppEnv } from "../types";

const MAX_OPEN_TOURNAMENTS = 3;

const createSchema = z.object({
  name: z.string().trim().min(3, { error: "Mínimo 3 caracteres" }).max(40, { error: "Máximo 40 caracteres" }),
  description: z.string().trim().max(200).default(""),
  format: z.enum(["league", "cup", "groups_cup"]),
  visibility: z.enum(["private", "public"]).default("private"),
});

/** Organizar un torneo desde un servidor (owner o admin del anfitrión). Va dentro de `/clubs`. */
export const hostTournamentRoutes = new Hono<AppEnv>();

hostTournamentRoutes.post("/:clubId/tournaments", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const at = now.toISOString();
  const user = c.var.auth.user;
  const body = await readJson(c, createSchema);
  const { club: host, member } = await requireMembership(db, c.req.param("clubId"), user.id);
  if (host.kind !== "group") throw errors.wrongKind(true);
  if (host.status !== "active") throw errors.clubSuspended();
  if (!isAdmin(member.role)) throw errors.forbidden();
  const open = await db
    .prepare(
      `SELECT COUNT(*) AS n FROM clubs c JOIN tournaments t ON t.club_id = c.id
        WHERE c.host_club_id = ? AND c.status = 'active' AND t.status <> 'finished'`,
    )
    .bind(host.id)
    .first<{ n: number }>();
  if (open!.n >= MAX_OPEN_TOURNAMENTS) throw errors.tooManyTournaments();

  const id = crypto.randomUUID();
  const ownerMemberId = crypto.randomUUID();
  await db.batch([
    db
      .prepare(
        `INSERT INTO clubs (id, name, description, status, owner_user_id, settings, kind, visibility, color, host_club_id,
                            reviewed_by, reviewed_at, created_at, updated_at)
         VALUES (?, ?, ?, 'active', ?, ?, 'tournament', ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        id,
        body.name,
        body.description,
        user.id,
        JSON.stringify({ ...DEFAULT_SETTINGS, timezone: host.settings.timezone }),
        body.visibility,
        host.color,
        host.id,
        user.id,
        at,
        at,
        at,
      ),
    db
      .prepare(
        `INSERT INTO members (id, club_id, user_id, role, display_name, created_by, created_at, updated_at)
         VALUES (?, ?, ?, 'owner', ?, ?, ?, ?)`,
      )
      .bind(ownerMemberId, id, user.id, user.displayName, user.id, at, at),
    db
      .prepare("INSERT INTO tournaments (club_id, format, status, created_at, updated_at) VALUES (?, ?, 'draft', ?, ?)")
      .bind(id, body.format, at, at),
    changeStatement(db, id, upsert("club", id), now),
    changeStatement(db, id, upsert("member", ownerMemberId), now),
    changeStatement(db, id, upsert("tournament", id), now),
    auditStatement(db, { clubId: id, actorUserId: user.id, action: "tournament.create", entity: "club", entityKey: id, summary: { host: host.id } }, now),
    auditStatement(db, { clubId: host.id, actorUserId: user.id, action: "tournament.create", entity: "club", entityKey: id, summary: { name: body.name } }, now),
  ]);
  return c.json({ club: { id, name: body.name, kind: "tournament" } }, 201);
});

const teamSchema = z.object({
  name: z.string().trim().min(2, { error: "Mínimo 2 caracteres" }).max(30, { error: "Máximo 30 caracteres" }),
  shortName: z
    .string()
    .trim()
    .toUpperCase()
    .regex(/^[A-Z0-9ÁÉÍÓÚÑ]{2,4}$/, { error: "De 2 a 4 letras" }),
  color: z.number().int().min(0).max(7).default(0),
  representsClubId: z.string().min(1).max(64).nullable().optional(),
});

/** Inscribir un equipo en un torneo público desde el directorio: se entra y se queda de capitán. */
export const tournamentRoutes = new Hono<AppEnv>();

tournamentRoutes.use(requireAuth);

tournamentRoutes.post("/:clubId/teams", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const at = now.toISOString();
  const user = c.var.auth.user;
  const body = await readJson(c, teamSchema);
  const t = await db
    .prepare(
      `SELECT c.id, c.name, t.status, t.registration_closes_at FROM clubs c JOIN tournaments t ON t.club_id = c.id
        WHERE c.id = ? AND c.kind = 'tournament' AND c.visibility = 'public' AND c.status = 'active' AND c.delisted = 0`,
    )
    .bind(c.req.param("clubId"))
    .first<{ id: string; name: string; status: TournamentStatus; registration_closes_at: string | null }>();
  if (!t) throw errors.notFound();
  if (!registrationOpen(t.status, t.registration_closes_at, now)) throw errors.registrationClosed();

  const existing = await findMemberByUser(db, t.id, user.id);
  if (existing?.status === "banned") throw errors.bannedFromClub();
  let memberId = existing?.status === "active" ? existing.id : null;
  const statements: D1PreparedStatement[] = [];
  if (memberId) {
    const inTeam = await db
      .prepare("SELECT 1 FROM team_players WHERE club_id = ? AND member_id = ? AND status = 'active'")
      .bind(t.id, memberId)
      .first();
    if (inTeam) throw errors.alreadyInTeam();
  } else {
    const admit = await admitStatements(db, t.id, user, user.id, "team.register", now);
    memberId = admit.memberId;
    statements.push(...admit.statements);
  }
  if (body.representsClubId) {
    const ok = await db
      .prepare(
        `SELECT 1 FROM members m JOIN clubs c ON c.id = m.club_id
          WHERE m.club_id = ? AND m.user_id = ? AND m.status = 'active' AND c.status = 'active' AND c.kind = 'group'`,
      )
      .bind(body.representsClubId, user.id)
      .first();
    if (!ok) throw errors.invalidInput({ representsClubId: ["No eres miembro de ese servidor"] });
  }
  const teamId = crypto.randomUUID();
  statements.push(
    db
      .prepare(
        `INSERT INTO teams (id, club_id, name, short_name, color, captain_member_id, represents_club_id, status, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)`,
      )
      .bind(teamId, t.id, body.name, body.shortName, body.color, memberId, body.representsClubId ?? null, at, at),
    db
      .prepare("INSERT INTO team_players (id, club_id, team_id, member_id, status, updated_at) VALUES (?, ?, ?, ?, 'active', ?)")
      .bind(`${teamId}:${memberId}`, t.id, teamId, memberId, at),
    changeStatement(db, t.id, upsert("team", teamId), now),
    changeStatement(db, t.id, upsert("teamPlayer", `${teamId}:${memberId}`), now),
    auditStatement(db, { clubId: t.id, actorUserId: user.id, action: "team.register", entity: "team", entityKey: teamId, summary: { name: body.name } }, now),
  );
  try {
    await db.batch(statements);
  } catch (e) {
    // Otra inscripción suya a la vez ya lo metió en un equipo (o en el torneo).
    if (String(e).includes("UNIQUE constraint failed")) throw errors.alreadyInTeam();
    throw e;
  }
  return c.json({ club: { id: t.id, name: t.name }, team: { id: teamId, status: "pending" } }, 201);
});
