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

// `clubs` se rellena en el PR2 (servidores). Hasta entonces, siempre vacío.
meRoutes.get("/", (c) => c.json({ user: c.var.auth.user, clubs: [] }));

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
  await db.batch([
    deleteUserSessionsStatement(db, userId),
    db.prepare("DELETE FROM recovery_codes WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM users WHERE id = ?").bind(userId),
  ]);
  return c.body(null, 204);
});
