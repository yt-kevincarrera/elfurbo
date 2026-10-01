import { Hono } from "hono";
import { createMiddleware } from "hono/factory";
import { z } from "zod";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { findUserById } from "../auth/users";
import { findClub, findMember, type ClubStatus } from "../clubs/model";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import type { AppEnv } from "../types";

const requireSuperadmin = createMiddleware<AppEnv>(async (c, next) => {
  if (!c.var.auth.user.isSuperadmin) throw errors.forbidden();
  await next();
});

export const superadminRoutes = new Hono<AppEnv>();

superadminRoutes.use(requireAuth, requireSuperadmin);

const noteSchema = z.object({ note: z.string().trim().max(300).default("") });
const transferSchema = z.object({ memberId: z.string().min(1).max(64) });

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
  await db.batch([
    db
      .prepare("UPDATE clubs SET status = 'active', reviewed_by = ?, reviewed_at = ?, updated_at = ? WHERE id = ?")
      .bind(actor, at, at, club.id),
    db
      .prepare(
        `INSERT INTO members (id, club_id, user_id, role, display_name, created_by, created_at, updated_at)
         VALUES (?, ?, ?, 'owner', ?, ?, ?, ?)`,
      )
      .bind(crypto.randomUUID(), club.id, owner.id, owner.displayName, actor, at, at),
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
    auditStatement(db, { clubId: club.id, actorUserId: actor, action, entity: "club", entityKey: club.id, summary: note ? { note } : {} }, now),
  ]);
  return { club: { id: club.id, status: to } };
}

/** El dueño actual pasa a admin y el miembro elegido (con cuenta) pasa a dueño. */
superadminRoutes.post("/clubs/:id/transfer", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const at = now.toISOString();
  const actor = c.var.auth.user.id;
  const { memberId } = await readJson(c, transferSchema);
  const club = await loadClubIn(db, c.req.param("id"), ["active", "suspended"]);
  const target = await findMember(db, club.id, memberId);
  if (!target || target.status !== "active" || !target.userId) {
    throw errors.invalidInput({ memberId: ["Tiene que ser un miembro activo con cuenta"] });
  }
  if (target.role === "owner") throw errors.invalidState("Ese miembro ya es el dueño");
  await db.batch([
    db
      .prepare("UPDATE members SET role = 'admin', updated_at = ? WHERE club_id = ? AND role = 'owner'")
      .bind(at, club.id),
    db.prepare("UPDATE members SET role = 'owner', updated_at = ? WHERE id = ?").bind(at, target.id),
    db.prepare("UPDATE clubs SET owner_user_id = ?, updated_at = ? WHERE id = ?").bind(target.userId, at, club.id),
    auditStatement(
      db,
      { clubId: club.id, actorUserId: actor, action: "club.transfer", entity: "club", entityKey: club.id, summary: { from: club.ownerUserId, to: target.userId } },
      now,
    ),
  ]);
  return c.json({ club: { id: club.id, ownerUserId: target.userId } });
});
