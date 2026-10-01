import { Hono } from "hono";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import type { AppEnv } from "../types";
import { DEFAULT_SETTINGS } from "./model";
import { clubRequestSchema } from "./schemas";

const MAX_OWNED_CLUBS = 3;

export const clubRoutes = new Hono<AppEnv>();

clubRoutes.use(requireAuth);

/** Solicitar un servidor. Queda `pending` hasta que el superadmin lo apruebe. */
clubRoutes.post("/", async (c) => {
  const body = await readJson(c, clubRequestSchema);
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;

  const owned = await db
    .prepare("SELECT COUNT(*) AS n FROM clubs WHERE owner_user_id = ? AND status IN ('pending', 'active')")
    .bind(userId)
    .first<{ n: number }>();
  if (owned!.n >= MAX_OWNED_CLUBS) throw errors.tooManyClubs();

  const id = crypto.randomUUID();
  const at = now.toISOString();
  await db.batch([
    db
      .prepare(
        `INSERT INTO clubs (id, name, description, status, owner_user_id, request_note, settings, created_at, updated_at)
         VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?)`,
      )
      .bind(id, body.name, body.description, userId, body.requestNote, JSON.stringify(DEFAULT_SETTINGS), at, at),
    auditStatement(db, { clubId: id, actorUserId: userId, action: "club.request", entity: "club", entityKey: id }, now),
  ]);
  return c.json({ club: { id, name: body.name, status: "pending" } }, 201);
});

