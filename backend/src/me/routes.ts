import { Hono } from "hono";
import { z } from "zod";
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
      `SELECT c.id, c.name, c.status, c.kind, c.color, c.official, m.id AS member_id, m.role,
              CASE WHEN c.official = 1 THEN 'official' ELSE COALESCE(cm.tier, 'new') END AS tier
         FROM members m JOIN clubs c ON c.id = m.club_id LEFT JOIN club_metrics cm ON cm.club_id = c.id
        WHERE m.user_id = ? AND m.status = 'active' AND c.status IN ('active', 'suspended')
        ORDER BY c.name`,
    )
    .bind(userId)
    .all<{ id: string; name: string; status: string; kind: string; color: number; official: number; member_id: string; role: string; tier: string }>();
  const requests = await db
    .prepare(
      `SELECT id, name, status, review_note, created_at FROM clubs
        WHERE owner_user_id = ? AND status IN ('pending', 'rejected') ORDER BY created_at DESC`,
    )
    .bind(userId)
    .all<{ id: string; name: string; status: string; review_note: string | null; created_at: string }>();
  // Mis solicitudes para entrar: las pendientes y las rechazadas del último mes.
  const joins = await db
    .prepare(
      `SELECT j.id, j.club_id, c.name, j.status, j.note, j.created_at, j.decided_at
         FROM join_requests j JOIN clubs c ON c.id = j.club_id
        WHERE j.user_id = ?
          AND ((j.status = 'pending' AND c.visibility = 'public' AND c.status = 'active' AND c.delisted = 0)
               OR (j.status = 'rejected' AND j.decided_at > ?))
        ORDER BY j.created_at DESC`,
    )
    .bind(userId, new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString())
    .all<{ id: string; club_id: string; name: string; status: string; note: string | null; created_at: string; decided_at: string | null }>();
  // Las que esperan respuesta en los servidores donde soy owner o admin.
  const toAnswer = await db
    .prepare(
      `SELECT j.id, j.club_id, c.name, u.display_name
         FROM join_requests j JOIN clubs c ON c.id = j.club_id JOIN users u ON u.id = j.user_id
         JOIN members m ON m.club_id = j.club_id AND m.user_id = ?1
        WHERE j.status = 'pending' AND m.status = 'active' AND m.role IN ('owner', 'admin') AND c.status = 'active'
        ORDER BY j.created_at DESC LIMIT 50`,
    )
    .bind(userId)
    .all<{ id: string; club_id: string; name: string; display_name: string }>();
  const prefs = await db
    .prepare("SELECT show_private_stats FROM users WHERE id = ?")
    .bind(userId)
    .first<{ show_private_stats: number }>();
  return c.json({
    user: c.var.auth.user,
    settings: { showPrivateStats: prefs?.show_private_stats !== 0 },
    clubs: clubs.results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      kind: r.kind,
      color: r.color,
      official: r.official === 1,
      memberId: r.member_id,
      role: r.role,
      tier: r.tier,
    })),
    clubRequests: requests.results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      reviewNote: r.review_note,
      createdAt: r.created_at,
    })),
    joinRequests: joins.results.map((r) => ({
      id: r.id,
      clubId: r.club_id,
      clubName: r.name,
      status: r.status,
      note: r.note,
      createdAt: r.created_at,
      decidedAt: r.decided_at,
    })),
    pendingJoinRequests: toAnswer.results.map((r) => ({
      id: r.id,
      clubId: r.club_id,
      clubName: r.name,
      displayName: r.display_name,
    })),
  });
});

const meSettingsSchema = z.object({ showPrivateStats: z.boolean() }).strict();

/** Ajustes de la cuenta: si lo de mis servidores privados sale en mi perfil global (spec 2.0 §5). */
meRoutes.patch("/", async (c) => {
  const { showPrivateStats } = await readJson(c, meSettingsSchema);
  await c.env.DB.prepare("UPDATE users SET show_private_stats = ?, updated_at = ? WHERE id = ?")
    .bind(showPrivateStats ? 1 : 0, new Date().toISOString(), c.var.auth.user.id)
    .run();
  return c.json({ settings: { showPrivateStats } });
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
