import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { authRoutes } from "./auth/routes";
import { errorResponse, errors, handleError } from "./http/errors";
import type { AppEnv } from "./types";

const app = new Hono<AppEnv>();

app.use(bodyLimit({ maxSize: 64 * 1024, onError: (c) => errorResponse(c, errors.payloadTooLarge()) }));

app.get("/health", (c) => c.json({ ok: true, environment: c.env.ENVIRONMENT }));
app.route("/auth", authRoutes);

app.notFound((c) => errorResponse(c, errors.notFound()));
app.onError(handleError);

export default app;
