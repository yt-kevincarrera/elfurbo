import { Hono } from "hono";
import { verifyPassword } from "../auth/crypto";
import { requireAuth } from "../auth/middleware";
import { assertNotLocked, authLimits, recordAttempt } from "../auth/rate-limit";
import { confirmPasswordSchema } from "../auth/schemas";
import { deleteUserSessionsStatement } from "../auth/sessions";
import { findUserById } from "../auth/users";
import { errors } from "../http/errors";
import { clientIp, readJson } from "../http/validate";
import type { AppEnv } from "../types";

export const meRoutes = new Hono<AppEnv>();

meRoutes.use(requireAuth);

/** El usuario, los servidores donde es miembro activo y sus solicitudes pendientes o rechazadas. */
meRoutes.get("/", async (c) => {
  const db = c.env.DB;
  const userId = c.var.auth.user.id;
  const clubs = await db
    .prepare(
      `SELECT c.id, c.name, c.status, c.kind, c.color, c.official, m.id AS member_id, m.role
         FROM members m JOIN clubs c ON c.id = m.club_id
        WHERE m.user_id = ? AND m.status = 'active' AND c.status IN ('active', 'suspended')
        ORDER BY c.name`,
    )
    .bind(userId)
    .all<{ id: string; name: string; status: string; kind: string; color: number; official: number; member_id: string; role: string }>();
  const requests = await db
    .prepare(
      `SELECT id, name, status, review_note, created_at FROM clubs
        WHERE owner_user_id = ? AND status IN ('pending', 'rejected') ORDER BY created_at DESC`,
    )
    .bind(userId)
    .all<{ id: string; name: string; status: string; review_note: string | null; created_at: string }>();
  return c.json({
    user: c.var.auth.user,
    clubs: clubs.results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      kind: r.kind,
      color: r.color,
      official: r.official === 1,
      memberId: r.member_id,
      role: r.role,
    })),
    clubRequests: requests.results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      reviewNote: r.review_note,
      createdAt: r.created_at,
    })),
  });
});

meRoutes.delete("/", async (c) => {
  const body = await readJson(c, confirmPasswordSchema);
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const rateLimits = authLimits.login(c.var.auth.user.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = (await findUserById(db, userId))!;
  if (!(await verifyPassword(body.password, user.passwordHash))) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidCredentials();
  }
  const owns = await db
    .prepare("SELECT 1 FROM clubs WHERE owner_user_id = ? AND status IN ('active', 'suspended') LIMIT 1")
    .bind(userId)
    .first();
  if (owns) throw errors.ownerMustTransfer();

  const at = now.toISOString();
  await db.batch([
    // Avisa al pull de cada servidor antes de desvincular los perfiles.
    db
      .prepare(
        "INSERT INTO changes (club_id, entity, entity_key, op, at) SELECT club_id, 'member', id, 'upsert', ? FROM members WHERE user_id = ?",
      )
      .bind(at, userId),
    // Sus estadísticas se quedan en cada servidor, a nombre de "Jugador eliminado".
    db
      .prepare(
        "UPDATE members SET user_id = NULL, role = 'guest', display_name = 'Jugador eliminado', nickname = NULL, updated_at = ? WHERE user_id = ?",
      )
      .bind(at, userId),
    db.prepare("DELETE FROM clubs WHERE owner_user_id = ? AND status IN ('pending', 'rejected')").bind(userId),
    deleteUserSessionsStatement(db, userId),
    db.prepare("DELETE FROM recovery_codes WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM users WHERE id = ?").bind(userId),
  ]);
  return c.body(null, 204);
});
