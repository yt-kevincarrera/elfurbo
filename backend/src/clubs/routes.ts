import { Hono } from "hono";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { randomCode } from "../auth/crypto";
import { canInviteAs, canManageInvites } from "../authz";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import { findInvite, formatCode } from "../invites/model";
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
  if (!canInviteAs(member.role, role)) throw errors.forbidden();

  const code = randomCode();
  const expiresAt = new Date(now.getTime() + body.expiresInDays * DAY_MS).toISOString();
  await db.batch([
    db
      .prepare(
        `INSERT INTO invites (code, club_id, role, target_member_id, max_uses, expires_at, created_by, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(code, club.id, role, body.targetMemberId ?? null, maxUses, expiresAt, userId, now.toISOString()),
    auditStatement(
      db,
      { clubId: club.id, actorUserId: userId, action: "invite.create", entity: "invite", entityKey: code, summary: { role, maxUses } },
      now,
    ),
  ]);
  return c.json(
    { invite: { code: formatCode(code), role, maxUses, uses: 0, expiresAt, targetMemberId: body.targetMemberId ?? null } },
    201,
  );
});

clubRoutes.get("/:clubId/invites", async (c) => {
  const db = c.env.DB;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), c.var.auth.user.id);
  if (!canManageInvites(member.role)) throw errors.forbidden();
  const { results } = await db
    .prepare(
      `SELECT code, role, target_member_id, max_uses, uses, expires_at FROM invites
        WHERE club_id = ? AND revoked_at IS NULL AND expires_at > ? AND uses < max_uses
        ORDER BY created_at DESC`,
    )
    .bind(club.id, new Date().toISOString())
    .all<{ code: string; role: string; target_member_id: string | null; max_uses: number; uses: number; expires_at: string }>();
  return c.json({
    invites: results.map((r) => ({
      code: formatCode(r.code),
      role: r.role,
      maxUses: r.max_uses,
      uses: r.uses,
      expiresAt: r.expires_at,
      targetMemberId: r.target_member_id,
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
  await db.batch([
    db.prepare("UPDATE invites SET revoked_at = ? WHERE code = ?").bind(now.toISOString(), invite.code),
    auditStatement(db, { clubId: club.id, actorUserId: userId, action: "invite.revoke", entity: "invite", entityKey: invite.code }, now),
  ]);
  return c.body(null, 204);
});
