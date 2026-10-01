import { Hono } from "hono";
import { requireAuth } from "../auth/middleware";
import type { AppEnv } from "../types";

export const meRoutes = new Hono<AppEnv>();

meRoutes.use(requireAuth);

// `clubs` se rellena en el PR2 (servidores). Hasta entonces, siempre vacío.
meRoutes.get("/", (c) => c.json({ user: c.var.auth.user, clubs: [] }));
