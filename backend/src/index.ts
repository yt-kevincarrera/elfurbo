import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { authRoutes } from "./auth/routes";
import { clubRoutes } from "./clubs/routes";
import { errorResponse, errors, handleError } from "./http/errors";
import { invitePageRoutes, inviteRoutes } from "./invites/routes";
import { meRoutes } from "./me/routes";
import { superadminRoutes } from "./superadmin/routes";
import { syncRoutes } from "./sync/routes";
import type { AppEnv } from "./types";

const app = new Hono<AppEnv>();

// 64 KB para todo menos el push de sync, que admite hasta 256 KB (lo pone su propia ruta).
const smallBodies = bodyLimit({ maxSize: 64 * 1024, onError: (c) => errorResponse(c, errors.payloadTooLarge()) });
app.use((c, next) => (c.req.path === "/sync/push" ? next() : smallBodies(c, next)));

app.get("/health", (c) => c.json({ ok: true, environment: c.env.ENVIRONMENT }));
app.route("/auth", authRoutes);
app.route("/me", meRoutes);
app.route("/clubs", clubRoutes);
app.route("/invites", inviteRoutes);
app.route("/i", invitePageRoutes);
app.route("/admin", superadminRoutes);
app.route("/sync", syncRoutes);

app.notFound((c) => errorResponse(c, errors.notFound()));
app.onError(handleError);

export default app;
