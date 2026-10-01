import { Hono } from "hono";
import { createMiddleware } from "hono/factory";
import { z } from "zod";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { issueRecoveryCode } from "../auth/recovery";
import { findUserById } from "../auth/users";
import { findClub, type ClubStatus } from "../clubs/model";
import { transferOwnership } from "../clubs/transfer";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import { changeStatement, upsert } from "../sync/changes";
import type { AppEnv } from "../types";

const requireSuperadmin = createMiddleware<AppEnv>(async (c, next) => {
  if (!c.var.auth.user.isSuperadmin) throw errors.forbidden();
  await next();
});

export const superadminRoutes = new Hono<AppEnv>();

superadminRoutes.use(requireAuth, requireSuperadmin);

const noteSchema = z.object({ note: z.string().trim().max(300).default("") });
const transferSchema = z.object({ memberId: z.string().min(1).max(64) });
const DAY_MS = 24 * 60 * 60 * 1000;

/** `?q=` busca en nombre o nombre de usuario del dueño; `\`, `%` y `_` se buscan literalmente. */
function likePattern(q: string) {
  return `%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`;
}

superadminRoutes.get("/clubs", async (c) => {
  const status = z.enum(["pending", "active", "rejected", "suspended"]).optional().safeParse(c.req.query("status"));
  if (!status.success) throw errors.invalidInput({ status: ["Estado no válido"] });
  const q = (c.req.query("q") ?? "").trim().toLowerCase();
  const { results } = await c.env.DB.prepare(
    `SELECT c.id, c.name, c.status, c.request_note, c.created_at, u.username AS owner_username,
            (SELECT COUNT(*) FROM members m WHERE m.club_id = c.id AND m.status = 'active') AS members
       FROM clubs c LEFT JOIN users u ON u.id = c.owner_user_id
      WHERE (?1 IS NULL OR c.status = ?1)
        AND (?2 = '' OR lower(c.name) LIKE ?3 ESCAPE '\\' OR u.username LIKE ?3 ESCAPE '\\')
      ORDER BY c.created_at DESC LIMIT 100`,
  )
    .bind(status.data ?? null, q, likePattern(q))
    .all<{ id: string; name: string; status: ClubStatus; request_note: string; created_at: string; owner_username: string | null; members: number }>();
  return c.json({
    clubs: results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      requestNote: r.request_note,
      createdAt: r.created_at,
      ownerUsername: r.owner_username,
      members: r.members,
    })),
  });
});

superadminRoutes.get("/clubs/:id", async (c) => {
  const club = await findClub(c.env.DB, c.req.param("id"));
  if (!club) throw errors.notFound();
  const { results } = await c.env.DB.prepare(
    "SELECT role, COUNT(*) AS n FROM members WHERE club_id = ? AND status = 'active' GROUP BY role",
  )
    .bind(club.id)
    .all<{ role: string; n: number }>();
  const owner = await findUserById(c.env.DB, club.ownerUserId);
  return c.json({
    club: { id: club.id, name: club.name, description: club.description, status: club.status, settings: club.settings },
    owner: owner ? { id: owner.id, username: owner.username, displayName: owner.displayName } : null,
    membersByRole: Object.fromEntries(results.map((r) => [r.role, r.n])),
  });
});

/** El club, si su estado es uno de `from`; si no, 404 o 409. */
async function loadClubIn(db: D1Database, id: string, from: ClubStatus[]) {
  const club = await findClub(db, id);
  if (!club) throw errors.notFound();
  if (!from.includes(club.status)) throw errors.invalidState(`El servidor está ${club.status}`);
  return club;
}

superadminRoutes.post("/clubs/:id/approve", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const at = now.toISOString();
  const actor = c.var.auth.user.id;
  const club = await loadClubIn(db, c.req.param("id"), ["pending"]);
  const owner = await findUserById(db, club.ownerUserId);
  if (!owner) throw errors.invalidState("El solicitante ya no tiene cuenta");
  const ownerMemberId = crypto.randomUUID();
  const seasonId = crypto.randomUUID();
  const year = new Intl.DateTimeFormat("en", { timeZone: club.settings.timezone, year: "numeric" }).format(now);
  await db.batch([
    db
      .prepare("UPDATE clubs SET status = 'active', reviewed_by = ?, reviewed_at = ?, updated_at = ? WHERE id = ?")
      .bind(actor, at, at, club.id),
    db
      .prepare(
        `INSERT INTO members (id, club_id, user_id, role, display_name, created_by, created_at, updated_at)
         VALUES (?, ?, ?, 'owner', ?, ?, ?, ?)`,
      )
      .bind(ownerMemberId, club.id, owner.id, owner.displayName, actor, at, at),
    // Temporada inicial: el año en curso en la zona horaria del servidor.
    db
      .prepare(
        "INSERT INTO seasons (id, club_id, name, start_date, is_active, created_at, updated_at) VALUES (?, ?, ?, ?, 1, ?, ?)",
      )
      .bind(seasonId, club.id, year, `${year}-01-01`, at, at),
    changeStatement(db, club.id, upsert("club", club.id), now),
    changeStatement(db, club.id, upsert("member", ownerMemberId), now),
    changeStatement(db, club.id, upsert("season", seasonId), now),
    auditStatement(db, { clubId: club.id, actorUserId: actor, action: "club.approve", entity: "club", entityKey: club.id }, now),
  ]);
  return c.json({ club: { id: club.id, status: "active" } });
});

superadminRoutes.post("/clubs/:id/reject", async (c) => {
  const { note } = await readJson(c, noteSchema);
  return c.json(await setClubStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), ["pending"], "rejected", "club.reject", note));
});

superadminRoutes.post("/clubs/:id/suspend", async (c) => {
  const { note } = await readJson(c, noteSchema);
  return c.json(await setClubStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), ["active"], "suspended", "club.suspend", note));
});

superadminRoutes.post("/clubs/:id/reactivate", async (c) =>
  c.json(await setClubStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), ["suspended"], "active", "club.reactivate", null)),
);

async function setClubStatus(
  db: D1Database,
  actor: string,
  id: string,
  from: ClubStatus[],
  to: ClubStatus,
  action: string,
  note: string | null,
) {
  const now = new Date();
  const at = now.toISOString();
  const club = await loadClubIn(db, id, from);
  await db.batch([
    db
      .prepare(
        "UPDATE clubs SET status = ?, review_note = COALESCE(?, review_note), reviewed_by = ?, reviewed_at = ?, updated_at = ? WHERE id = ?",
      )
      .bind(to, note, actor, at, at, club.id),
    changeStatement(db, club.id, upsert("club", club.id), now),
    auditStatement(db, { clubId: club.id, actorUserId: actor, action, entity: "club", entityKey: club.id, summary: note ? { note } : {} }, now),
  ]);
  return { club: { id: club.id, status: to } };
}

/** El dueño actual pasa a admin y el miembro elegido (con cuenta) pasa a dueño. */
superadminRoutes.post("/clubs/:id/transfer", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const actor = c.var.auth.user.id;
  const { memberId } = await readJson(c, transferSchema);
  const club = await loadClubIn(db, c.req.param("id"), ["active", "suspended"]);
  const t = await transferOwnership(db, club, memberId, now);
  await db.batch([
    ...t.statements,
    ...t.touched.map((touch) => changeStatement(db, club.id, touch, now)),
    auditStatement(
      db,
      { clubId: club.id, actorUserId: actor, action: "club.transfer", entity: "club", entityKey: club.id, summary: { from: club.ownerUserId, to: t.target.userId } },
      now,
    ),
  ]);
  return c.json({ club: { id: club.id, ownerUserId: t.target.userId } });
});

superadminRoutes.get("/users", async (c) => {
  const q = (c.req.query("q") ?? "").trim().toLowerCase();
  const { results } = await c.env.DB.prepare(
    `SELECT u.id, u.username, u.display_name, u.status, u.is_superadmin, u.created_at,
            (SELECT MAX(s.last_seen_at) FROM sessions s WHERE s.user_id = u.id) AS last_seen_at
       FROM users u
      WHERE ?1 = '' OR u.username LIKE ?2 ESCAPE '\\'
      ORDER BY u.username LIMIT 50`,
  )
    .bind(q, likePattern(q))
    .all<{ id: string; username: string; display_name: string; status: string; is_superadmin: number; created_at: string; last_seen_at: string | null }>();
  return c.json({
    users: results.map((r) => ({
      id: r.id,
      username: r.username,
      displayName: r.display_name,
      status: r.status,
      isSuperadmin: r.is_superadmin === 1,
      createdAt: r.created_at,
      lastSeenAt: r.last_seen_at,
    })),
  });
});

async function loadOtherUser(db: D1Database, actorId: string, id: string) {
  const user = await findUserById(db, id);
  if (!user) throw errors.notFound();
  if (user.id === actorId || user.isSuperadmin) throw errors.forbidden();
  return user;
}

superadminRoutes.post("/users/:id/suspend", async (c) =>
  c.json(await setUserStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), "suspended")),
);
superadminRoutes.post("/users/:id/unsuspend", async (c) =>
  c.json(await setUserStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), "active")),
);

async function setUserStatus(
  db: D1Database,
  actor: string,
  id: string,
  status: "active" | "suspended",
) {
  const now = new Date();
  const user = await loadOtherUser(db, actor, id);
  await db.batch([
    db.prepare("UPDATE users SET status = ?, updated_at = ? WHERE id = ?").bind(status, now.toISOString(), user.id),
    auditStatement(
      db,
      { clubId: null, actorUserId: actor, action: status === "suspended" ? "user.suspend" : "user.unsuspend", entity: "user", entityKey: user.id },
      now,
    ),
  ]);
  return { user: { id: user.id, status } };
}

superadminRoutes.post("/users/:id/recovery-code", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const actor = c.var.auth.user.id;
  const user = await findUserById(db, c.req.param("id"));
  if (!user) throw errors.notFound();
  if (user.id === actor) throw errors.forbidden();
  const issued = await issueRecoveryCode(db, user.id, actor, now);
  await db.batch([
    ...issued.statements,
    auditStatement(db, { clubId: null, actorUserId: actor, action: "recovery.issue", entity: "user", entityKey: user.id }, now),
  ]);
  return c.json({ code: issued.code, expiresAt: issued.expiresAt }, 201);
});

superadminRoutes.get("/metrics", async (c) => {
  const now = Date.now();
  const since = (days: number) => new Date(now - days * DAY_MS).toISOString();
  const users = await c.env.DB.prepare(
    `SELECT COUNT(*) AS total,
            (SELECT COUNT(DISTINCT user_id) FROM sessions WHERE last_seen_at > ?1) AS active7d,
            (SELECT COUNT(DISTINCT user_id) FROM sessions WHERE last_seen_at > ?2) AS active30d
       FROM users`,
  )
    .bind(since(7), since(30))
    .first<{ total: number; active7d: number; active30d: number }>();
  const { results } = await c.env.DB.prepare("SELECT status, COUNT(*) AS n FROM clubs GROUP BY status").all<{
    status: ClubStatus;
    n: number;
  }>();
  const clubs = { pending: 0, active: 0, rejected: 0, suspended: 0 };
  for (const r of results) clubs[r.status] = r.n;
  const commands = await c.env.DB.prepare(
    "SELECT COUNT(*) AS last24h FROM applied_commands WHERE at > ?",
  )
    .bind(since(1))
    .first<{ last24h: number }>();
  return c.json({ users, clubs, commands });
});
