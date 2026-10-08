import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { appRoutes } from "./app/routes";
import { authRoutes } from "./auth/routes";
import { clubRoutes } from "./clubs/routes";
import { scheduled } from "./cron";
import { errorResponse, errors, handleError } from "./http/errors";
import { invitePageRoutes, inviteRoutes } from "./invites/routes";
import { meRoutes } from "./me/routes";
import { playerRoutes } from "./players/routes";
import { superadminRoutes } from "./superadmin/routes";
import { syncRoutes } from "./sync/routes";
import type { AppEnv, Env } from "./types";

const app = new Hono<AppEnv>();

// 64 KB para todo menos el push de sync, que admite hasta 256 KB (lo pone su propia ruta).
const smallBodies = bodyLimit({ maxSize: 64 * 1024, onError: (c) => errorResponse(c, errors.payloadTooLarge()) });
app.use((c, next) => (c.req.path === "/sync/push" ? next() : smallBodies(c, next)));

app.get("/health", (c) => c.json({ ok: true, environment: c.env.ENVIRONMENT }));
app.route("/auth", authRoutes);
app.route("/me", meRoutes);
app.route("/players", playerRoutes);
app.route("/clubs", clubRoutes);
app.route("/invites", inviteRoutes);
app.route("/i", invitePageRoutes);
app.route("/admin", superadminRoutes);
// Una versión de la app más vieja que la que admite el protocolo de sync no envía ni trae nada
// (spec §8). La app manda su build en `x-app-build`; las que no lo mandan son anteriores a la 0.6.
app.use("/sync/*", async (c, next) => {
  const min = Number(c.env.MIN_SUPPORTED_BUILD ?? 0) || 0;
  const build = Number.parseInt(c.req.header("x-app-build") ?? "0", 10);
  if (min > 0 && !(build >= min)) throw errors.appOutdated();
  await next();
});
app.route("/sync", syncRoutes);
app.route("/app", appRoutes);

app.notFound((c) => errorResponse(c, errors.notFound()));
app.onError(handleError);

export default { fetch: app.fetch, scheduled } satisfies ExportedHandler<Env>;
