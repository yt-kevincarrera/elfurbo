import { createMiddleware } from "hono/factory";
import { errors } from "../http/errors";
import type { AppEnv } from "../types";
import { authenticate } from "./sessions";

/** Exige `Authorization: Bearer <token>` válido y deja la sesión en `c.var.auth`. */
export const requireAuth = createMiddleware<AppEnv>(async (c, next) => {
  const match = /^Bearer\s+(\S+)$/i.exec(c.req.header("authorization") ?? "");
  if (!match) throw errors.unauthorized();
  c.set("auth", await authenticate(c.env.DB, match[1]!, new Date()));
  await next();
});
