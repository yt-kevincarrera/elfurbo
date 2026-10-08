import { Hono } from "hono";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { randomCode } from "../auth/crypto";
import { issueRecoveryCode } from "../auth/recovery";
import { canInviteAs, canIssueRecoveryCode, canManageInvites, isAdmin, type InvitableRole } from "../authz";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import { findInvite, formatCode } from "../invites/model";
import { rostersOpen, type TournamentStatus } from "../rules/tournament";
import { prestigeOf } from "../stats/job";
import { hostTournamentRoutes } from "../tournaments/routes";
import { joinRoutes } from "./join";
import type { AppEnv } from "../types";
import { assertWritable, DEFAULT_SETTINGS, findMember, requireMembership } from "./model";
import { clubRequestSchema, createInviteSchema } from "./schemas";

const MAX_OWNED_CLUBS = 3;
const DAY_MS = 24 * 60 * 60 * 1000;

export const clubRoutes = new Hono<AppEnv>();

clubRoutes.use(requireAuth);

/** Solicitar un servidor. Queda `pending` hasta que el superadmin lo apruebe. */
clubRoutes.post("/", async (c) => {
  const body = await readJson(c, clubRequestSchema);
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;

  // Si se perdió la respuesta y la app reintenta, devuelve la misma solicitud en vez de duplicarla.
  const retried = await db
    .prepare("SELECT id FROM clubs WHERE owner_user_id = ? AND status = 'pending' AND lower(name) = lower(?)")
    .bind(userId, body.name)
    .first<{ id: string }>();
  if (retried) return c.json({ club: { id: retried.id, name: body.name, status: "pending" } }, 200);

  const owned = await db
    .prepare("SELECT COUNT(*) AS n FROM clubs WHERE owner_user_id = ? AND status IN ('pending', 'active')")
    .bind(userId)
    .first<{ n: number }>();
  if (owned!.n >= MAX_OWNED_CLUBS) throw errors.tooManyClubs();

  const id = crypto.randomUUID();
  const at = now.toISOString();
  await db.batch([
    db
      .prepare(
        `INSERT INTO clubs (id, name, description, status, owner_user_id, request_note, settings, created_at, updated_at)
         VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?)`,
      )
      .bind(id, body.name, body.description, userId, body.requestNote, JSON.stringify(DEFAULT_SETTINGS), at, at),
    auditStatement(db, { clubId: id, actorUserId: userId, action: "club.request", entity: "club", entityKey: id }, now),
  ]);
  return c.json({ club: { id, name: body.name, status: "pending" } }, 201);
});

clubRoutes.post("/:clubId/invites", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), userId);
  assertWritable(club);
  const body = await readJson(c, createInviteSchema);

  let { role, maxUses } = body;
  if (body.targetMemberId) {
    const target = await findMember(db, club.id, body.targetMemberId);
    if (!target || target.role !== "guest" || target.status !== "active") {
      throw errors.invalidInput({ targetMemberId: ["Ese jugador sin cuenta no existe en este servidor"] });
    }
    role = "player";
    maxUses = 1;
  }
  if (body.teamId) {
    // Una invitación de equipo no sirve para reclamar un perfil sin cuenta (eso es solo del staff).
    if (body.targetMemberId) throw errors.invalidInput({ teamId: ["Una invitación de equipo no reclama perfiles"] });
    // Invitación de equipo (torneos): la crean los organizadores o el capitán mientras no empiece.
    const team = await db
      .prepare(
        `SELECT tm.captain_member_id, tm.status, t.status AS tournament_status FROM teams tm
           JOIN tournaments t ON t.club_id = tm.club_id WHERE tm.id = ? AND tm.club_id = ?`,
      )
      .bind(body.teamId, club.id)
      .first<{ captain_member_id: string | null; status: string; tournament_status: TournamentStatus }>();
    if (!team || team.status === "withdrawn") throw errors.invalidInput({ teamId: ["Ese equipo no existe o se retiró"] });
    const captain = team.captain_member_id === member.id && rostersOpen(team.tournament_status);
    if (!isAdmin(member.role) && !captain) throw errors.forbidden();
    role = "player";
  } else if (!canInviteAs(member.role, role)) {
    throw errors.forbidden();
  }

  const code = randomCode();
  const expiresAt = new Date(now.getTime() + body.expiresInDays * DAY_MS).toISOString();
  await db.batch([
    db
      .prepare(
        `INSERT INTO invites (code, club_id, role, target_member_id, team_id, max_uses, expires_at, created_by, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(code, club.id, role, body.targetMemberId ?? null, body.teamId ?? null, maxUses, expiresAt, userId, now.toISOString()),
    auditStatement(
      db,
      { clubId: club.id, actorUserId: userId, action: "invite.create", entity: "invite", entityKey: code, summary: { role, maxUses } },
      now,
    ),
  ]);
  return c.json(
    {
      invite: {
        code: formatCode(code),
        role,
        maxUses,
        uses: 0,
        expiresAt,
        targetMemberId: body.targetMemberId ?? null,
        teamId: body.teamId ?? null,
      },
    },
    201,
  );
});

clubRoutes.get("/:clubId/invites", async (c) => {
  const db = c.env.DB;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), c.var.auth.user.id);
  if (!canManageInvites(member.role)) throw errors.forbidden();
  const { results } = await db
    .prepare(
      `SELECT code, role, target_member_id, team_id, max_uses, uses, expires_at FROM invites
        WHERE club_id = ? AND revoked_at IS NULL AND expires_at > ? AND uses < max_uses
        ORDER BY created_at DESC`,
    )
    .bind(club.id, new Date().toISOString())
    .all<{
      code: string;
      role: string;
      target_member_id: string | null;
      team_id: string | null;
      max_uses: number;
      uses: number;
      expires_at: string;
    }>();
  // Solo las que uno mismo podría crear: un admin no ve (ni reparte) las de admin del dueño.
  const visible = results.filter((r) => canInviteAs(member.role, r.role as InvitableRole));
  return c.json({
    invites: visible.map((r) => ({
      code: formatCode(r.code),
      role: r.role,
      maxUses: r.max_uses,
      uses: r.uses,
      expiresAt: r.expires_at,
      targetMemberId: r.target_member_id,
      teamId: r.team_id,
    })),
  });
});

clubRoutes.post("/:clubId/invites/:code/revoke", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), userId);
  if (!canManageInvites(member.role)) throw errors.forbidden();
  const invite = await findInvite(db, c.req.param("code"));
  if (!invite || invite.clubId !== club.id) throw errors.notFound();
  if (!canInviteAs(member.role, invite.role as InvitableRole)) throw errors.forbidden();
  await db.batch([
    db.prepare("UPDATE invites SET revoked_at = ? WHERE code = ?").bind(now.toISOString(), invite.code),
    auditStatement(db, { clubId: club.id, actorUserId: userId, action: "invite.revoke", entity: "invite", entityKey: invite.code }, now),
  ]);
  return c.body(null, 204);
});

/** Código de recuperación para un miembro que olvidó la contraseña. Se muestra una sola vez. */
clubRoutes.post("/:clubId/members/:memberId/recovery-code", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), userId);
  const target = await findMember(db, club.id, c.req.param("memberId"));
  if (!target || target.status !== "active") throw errors.notFound();
  if (target.id === member.id || !target.userId || !canIssueRecoveryCode(member.role, target.role)) {
    throw errors.forbidden();
  }
  // Con el código, quien lo genera puede entrar en la cuenta. Si esa cuenta es la del superadmin o
  // administra otro servidor, se quedaría con eso también: esos casos los resuelve el superadmin.
  const privileged = await db
    .prepare(
      `SELECT (SELECT is_superadmin FROM users WHERE id = ?1) AS superadmin,
              EXISTS (SELECT 1 FROM members m JOIN clubs c ON c.id = m.club_id
                       WHERE m.user_id = ?1 AND m.club_id <> ?2 AND m.status = 'active'
                         AND m.role IN ('owner', 'admin') AND c.status IN ('active', 'suspended')) AS elsewhere`,
    )
    .bind(target.userId, club.id)
    .first<{ superadmin: number | null; elsewhere: number }>();
  if (privileged!.superadmin === 1 || privileged!.elsewhere === 1) throw errors.recoveryNeedsSuperadmin();
  const issued = await issueRecoveryCode(db, target.userId, userId, now);
  await db.batch([
    ...issued.statements,
    auditStatement(db, { clubId: club.id, actorUserId: userId, action: "recovery.issue", entity: "member", entityKey: target.id }, now),
  ]);
  return c.json({ code: issued.code, expiresAt: issued.expiresAt }, 201);
});

/** Quién hizo qué en el servidor (owner y admin), lo más nuevo primero. `?before=<id>` pagina. */
clubRoutes.get("/:clubId/audit", async (c) => {
  const db = c.env.DB;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), c.var.auth.user.id);
  if (!isAdmin(member.role)) throw errors.forbidden();
  const limitQ = Number.parseInt(c.req.query("limit") ?? "", 10);
  const limit = Number.isSafeInteger(limitQ) ? Math.min(Math.max(limitQ, 1), 100) : 50;
  const beforeQ = Number.parseInt(c.req.query("before") ?? "", 10);
  const before = Number.isSafeInteger(beforeQ) && beforeQ > 0 ? beforeQ : null;
  const { results } = await db
    .prepare(
      `SELECT a.id, a.action, a.entity, a.entity_key, a.summary, a.at, u.username, u.display_name
         FROM audit_log a LEFT JOIN users u ON u.id = a.actor_user_id
        WHERE a.club_id = ?1 AND (?2 IS NULL OR a.id < ?2)
        ORDER BY a.id DESC LIMIT ?3`,
    )
    .bind(club.id, before, limit + 1)
    .all<{
      id: number;
      action: string;
      entity: string;
      entity_key: string;
      summary: string;
      at: string;
      username: string | null;
      display_name: string | null;
    }>();
  const page = results.slice(0, limit);
  return c.json({
    entries: page.map((r) => ({
      id: r.id,
      action: r.action,
      entity: r.entity,
      entityKey: r.entity_key,
      summary: JSON.parse(r.summary) as unknown,
      at: r.at,
      actor: r.username === null ? null : { username: r.username, displayName: r.display_name },
    })),
    next: results.length > limit ? page[page.length - 1]!.id : null,
  });
});

/**
 * El prestigio del servidor (spec 2.0 §4): nivel, puntuación por partes y qué le falta para subir.
 * Lo ve cualquier miembro; se recalcula cada pocos minutos.
 */
clubRoutes.get("/:clubId/prestige", async (c) => {
  const { club } = await requireMembership(c.env.DB, c.req.param("clubId"), c.var.auth.user.id);
  return c.json(await prestigeOf(c.env.DB, club));
});

clubRoutes.route("/", joinRoutes);
clubRoutes.route("/", hostTournamentRoutes);
