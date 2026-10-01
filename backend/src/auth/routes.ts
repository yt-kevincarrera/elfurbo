import { Hono } from "hono";
import { errors } from "../http/errors";
import { clientIp, readJson } from "../http/validate";
import type { AppEnv } from "../types";
import { DUMMY_HASH, hashPassword, normalizeCode, sha256Hex, verifyPassword } from "./crypto";
import { requireAuth } from "./middleware";
import { assertNotLocked, authLimits, clearAttempts, recordAttempt } from "./rate-limit";
import { changePasswordSchema, loginSchema, recoverSchema, registerSchema } from "./schemas";
import { deleteSessionStatement, deleteUserSessionsStatement, newSession } from "./sessions";
import {
  findUserById,
  findUserByUsername,
  insertUserStatement,
  toPublicUser,
  updatePasswordStatement,
} from "./users";

export const authRoutes = new Hono<AppEnv>();

authRoutes.post("/register", async (c) => {
  const body = await readJson(c, registerSchema);
  const db = c.env.DB;
  const now = new Date();
  const rateLimits = authLimits.register(clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  if (await findUserByUsername(db, body.username)) throw errors.usernameTaken();

  const user = {
    id: crypto.randomUUID(),
    username: body.username,
    displayName: body.displayName,
    passwordHash: await hashPassword(body.password),
  };
  const session = await newSession(db, user.id, body.deviceLabel ?? null, now);
  try {
    await db.batch([insertUserStatement(db, user, now), session.statement]);
  } catch (e) {
    // Dos registros simultáneos con el mismo nombre: gana el primero.
    if (String(e).includes("UNIQUE constraint failed: users.username")) throw errors.usernameTaken();
    throw e;
  }
  await recordAttempt(db, rateLimits, now);

  return c.json(
    {
      token: session.token,
      user: { id: user.id, username: user.username, displayName: user.displayName, isSuperadmin: false, status: "active" },
    },
    201,
  );
});

authRoutes.post("/login", async (c) => {
  const body = await readJson(c, loginSchema);
  const db = c.env.DB;
  const now = new Date();
  const rateLimits = authLimits.login(body.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = await findUserByUsername(db, body.username);
  const ok = await verifyPassword(body.password, user?.passwordHash ?? DUMMY_HASH);
  if (!user || !ok) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidCredentials();
  }
  if (user.status === "suspended") throw errors.accountSuspended();

  await clearAttempts(db, [rateLimits[0]!.key]);
  const session = await newSession(db, user.id, body.deviceLabel ?? null, now);
  await session.statement.run();
  return c.json({ token: session.token, user: toPublicUser(user) });
});

authRoutes.post("/logout", requireAuth, async (c) => {
  await deleteSessionStatement(c.env.DB, c.var.auth.sessionId).run();
  return c.body(null, 204);
});

authRoutes.post("/recover", async (c) => {
  const body = await readJson(c, recoverSchema);
  const db = c.env.DB;
  const now = new Date();
  const rateLimits = authLimits.recover(body.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = await findUserByUsername(db, body.username);
  const code = user
    ? await db
        .prepare(
          "SELECT id FROM recovery_codes WHERE user_id = ? AND code_hash = ? AND used_at IS NULL AND expires_at > ?",
        )
        .bind(user.id, await sha256Hex(normalizeCode(body.code)), now.toISOString())
        .first<{ id: string }>()
    : null;
  if (!user || !code) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidRecoveryCode();
  }
  if (user.status === "suspended") throw errors.accountSuspended();

  const session = await newSession(db, user.id, body.deviceLabel ?? null, now);
  await db.batch([
    db.prepare("UPDATE recovery_codes SET used_at = ? WHERE id = ?").bind(now.toISOString(), code.id),
    updatePasswordStatement(db, user.id, await hashPassword(body.newPassword), now),
    deleteUserSessionsStatement(db, user.id),
    session.statement,
  ]);
  await clearAttempts(db, [rateLimits[0]!.key]);
  return c.json({ token: session.token, user: toPublicUser(user) });
});

authRoutes.post("/password", requireAuth, async (c) => {
  const body = await readJson(c, changePasswordSchema);
  const db = c.env.DB;
  const now = new Date();
  const { user: authUser, sessionId } = c.var.auth;
  const rateLimits = authLimits.login(authUser.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = (await findUserById(db, authUser.id))!;
  if (!(await verifyPassword(body.currentPassword, user.passwordHash))) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidCredentials();
  }
  await db.batch([
    updatePasswordStatement(db, user.id, await hashPassword(body.newPassword), now),
    deleteUserSessionsStatement(db, user.id, sessionId),
  ]);
  return c.body(null, 204);
});
