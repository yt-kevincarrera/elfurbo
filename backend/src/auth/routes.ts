import { Hono } from "hono";
import { errors } from "../http/errors";
import { clientIp, readJson } from "../http/validate";
import type { AppEnv } from "../types";
import { hashPassword } from "./crypto";
import { assertNotLocked, authLimits, recordAttempt } from "./rate-limit";
import { registerSchema } from "./schemas";
import { newSession } from "./sessions";
import { findUserByUsername, insertUserStatement } from "./users";

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
