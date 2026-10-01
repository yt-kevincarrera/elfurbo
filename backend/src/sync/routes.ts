import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { requireAuth } from "../auth/middleware";
import { errorResponse, errors } from "../http/errors";
import { readJson } from "../http/validate";
import type { AppEnv } from "../types";
import { applyCommands, pushSchema } from "./push";

export const syncRoutes = new Hono<AppEnv>();

syncRoutes.use(requireAuth);

/** Hasta 200 comandos y 256 KB por envío (spec §5). */
syncRoutes.post(
  "/push",
  bodyLimit({ maxSize: 256 * 1024, onError: (c) => errorResponse(c, errors.payloadTooLarge()) }),
  async (c) => {
    const { commands } = await readJson(c, pushSchema);
    const results = await applyCommands(c.env.DB, c.var.auth.user, commands, new Date());
    return c.json({ results });
  },
);
