import { Hono } from "hono";
import { z } from "zod";
import { auditStatement } from "../audit";
import { isAdmin } from "../authz";
import { findPublicClub } from "../directory/model";
import { ApiError, errors } from "../http/errors";
import { readJson } from "../http/validate";
import type { AppEnv } from "../types";
import { admitStatements } from "./admit";
import { clubSettings, requireMembership } from "./model";

/** Pedir entrar en un servidor público y que un admin conteste (spec 2.0 §6). Va dentro de `/clubs` (con su sesión). */
export const joinRoutes = new Hono<AppEnv>();


const MAX_PENDING = 5;

const joinSchema = z.object({ message: z.string().trim().max(200, { error: "Máximo 200 caracteres" }).default("") });
const decideSchema = z.object({ note: z.string().trim().max(200).default("") });

/**
 * Pedir entrar. En uno abierto se entra al momento; si no, queda una solicitud pendiente (pedirlo
 * otra vez devuelve la misma). Privado o inexistente: 404.
 */
joinRoutes.post("/:clubId/join", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const user = c.var.auth.user;
  const { message } = await readJson(c, joinSchema);
  const club = await findPublicClub(db, c.req.param("clubId"), user.id);
  // A un torneo se entra inscribiendo un equipo (POST /tournaments/:id/teams), no así.
  if (club.kind !== "group") throw errors.wrongKind(true);
  if (club.my_member === "active") throw errors.alreadyMember();
  if (club.my_member === "banned") throw errors.bannedFromClub();

  if (clubSettings(club.settings).joinPolicy === "open") {
    const admit = await admitStatements(db, club.id, user, user.id, "join.open", now);
    try {
      // Una solicitud de cuando se entraba pidiéndolo queda contestada.
      await db.batch([...admit.statements, closePendingStatement(db, club.id, user.id, now)]);
    } catch (e) {
      // Dos peticiones a la vez del mismo usuario: gana la primera.
      if (String(e).includes("UNIQUE constraint failed")) throw errors.alreadyMember();
      throw e;
    }
    return c.json({ status: "member", club: { id: club.id, name: club.name } }, 201);
  }

  // Solo cuentan las de servidores que siguen siendo públicos y activos: las de uno que se hizo
  // privado o lo suspendieron no pueden bloquear otras.
  const pending = await db
    .prepare(
      `SELECT j.id, j.club_id FROM join_requests j JOIN clubs c ON c.id = j.club_id
        WHERE j.user_id = ? AND j.status = 'pending' AND c.visibility = 'public' AND c.status = 'active' AND c.delisted = 0`,
    )
    .bind(user.id)
    .all<{ id: string; club_id: string }>();
  const same = pending.results.find((r) => r.club_id === club.id);
  if (same) return c.json({ status: "pending", request: { id: same.id } });
  if (pending.results.length >= MAX_PENDING) throw errors.tooManyJoinRequests();

  const id = crypto.randomUUID();
  try {
    await db
      .prepare("INSERT INTO join_requests (id, club_id, user_id, message, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?)")
      .bind(id, club.id, user.id, message, now.toISOString())
      .run();
  } catch (e) {
    if (!String(e).includes("UNIQUE constraint failed")) throw e;
    // La pidió otra petición a la vez: esa vale.
    const row = await db
      .prepare("SELECT id FROM join_requests WHERE club_id = ? AND user_id = ? AND status = 'pending'")
      .bind(club.id, user.id)
      .first<{ id: string }>();
    return c.json({ status: "pending", request: { id: row!.id } });
  }
  return c.json({ status: "pending", request: { id } }, 201);
});

/** Retirar mi solicitud pendiente. */
joinRoutes.delete("/:clubId/join", async (c) => {
  await c.env.DB.prepare(
    "UPDATE join_requests SET status = 'cancelled', decided_at = ? WHERE club_id = ? AND user_id = ? AND status = 'pending'",
  )
    .bind(new Date().toISOString(), c.req.param("clubId"), c.var.auth.user.id)
    .run();
  return c.body(null, 204);
});

/** Las solicitudes pendientes (owner y admin), con lo que el que pide lleva jugado en toda la app. */
joinRoutes.get("/:clubId/join-requests", async (c) => {
  const db = c.env.DB;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), c.var.auth.user.id);
  if (!isAdmin(member.role)) throw errors.forbidden();
  const { results } = await db
    .prepare(
      `SELECT j.id, j.user_id, j.message, j.created_at, u.username, u.display_name,
              (SELECT COALESCE(SUM(ms.played), 0) FROM member_stats ms ${SHARED} WHERE m.user_id = j.user_id) AS played,
              (SELECT COALESCE(SUM(ms.goals), 0) FROM member_stats ms ${SHARED} WHERE m.user_id = j.user_id) AS goals
         FROM join_requests j JOIN users u ON u.id = j.user_id
        WHERE j.club_id = ? AND j.status = 'pending' ORDER BY j.created_at`,
    )
    .bind(club.id)
    .all<{
      id: string;
      user_id: string;
      message: string;
      created_at: string;
      username: string;
      display_name: string;
      played: number;
      goals: number;
    }>();
  return c.json({
    requests: results.map((r) => ({
      id: r.id,
      userId: r.user_id,
      username: r.username,
      displayName: r.display_name,
      message: r.message,
      createdAt: r.created_at,
      played: r.played,
      goals: r.goals,
    })),
  });
});

/**
 * Lo que cuenta en el perfil global (igual que sus totales): servidores activos que comparten sus
 * estadísticas. Nada de lo que el perfil esconde se cuela en el resumen.
 */
const SHARED = `JOIN members m ON m.id = ms.member_id JOIN clubs c ON c.id = m.club_id
  AND c.status = 'active' AND COALESCE(json_extract(c.settings, '$.shareStats'), 1) = 1`;

async function pendingRequest(db: D1Database, clubId: string, requestId: string) {
  const row = await db
    .prepare(
      `SELECT j.id, j.user_id, u.display_name FROM join_requests j JOIN users u ON u.id = j.user_id
        WHERE j.id = ? AND j.club_id = ? AND j.status = 'pending'`,
    )
    .bind(requestId, clubId)
    .first<{ id: string; user_id: string; display_name: string }>();
  if (!row) throw errors.notFound();
  return row;
}

joinRoutes.post("/:clubId/join-requests/:requestId/accept", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const actor = c.var.auth.user.id;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), actor);
  if (!isAdmin(member.role)) throw errors.forbidden();
  if (club.status === "suspended") throw errors.clubSuspended();
  const request = await pendingRequest(db, club.id, c.req.param("requestId"));
  // Primero se reclama la solicitud (como el uso de una invitación): si otro admin la contestó o el
  // que pidió la retiró mientras tanto, aquí se para y no entra nadie.
  const claimed = await db
    .prepare(
      "UPDATE join_requests SET status = 'accepted', decided_by = ?, decided_at = ? WHERE id = ? AND status = 'pending' RETURNING id",
    )
    .bind(actor, now.toISOString(), request.id)
    .first();
  if (!claimed) throw errors.notFound();
  const unclaim = () =>
    db
      .prepare("UPDATE join_requests SET status = 'pending', decided_by = NULL, decided_at = NULL WHERE id = ?")
      .bind(request.id)
      .run();
  let admit;
  try {
    admit = await admitStatements(db, club.id, { id: request.user_id, displayName: request.display_name }, actor, "join.accept", now);
  } catch (e) {
    // Ya entró por otro lado (una invitación): la solicitud queda contestada igual.
    if (e instanceof ApiError && e.code === "already_member") return c.json({ request: { id: request.id, status: "accepted" } });
    await unclaim();
    throw e;
  }
  try {
    await db.batch(admit.statements);
  } catch (e) {
    if (String(e).includes("UNIQUE constraint failed")) return c.json({ request: { id: request.id, status: "accepted" } });
    await unclaim();
    throw e;
  }
  return c.json({ request: { id: request.id, status: "accepted" }, member: { id: admit.memberId } });
});

joinRoutes.post("/:clubId/join-requests/:requestId/reject", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const actor = c.var.auth.user.id;
  const { note } = await readJson(c, decideSchema);
  const { club, member } = await requireMembership(db, c.req.param("clubId"), actor);
  if (!isAdmin(member.role)) throw errors.forbidden();
  const request = await pendingRequest(db, club.id, c.req.param("requestId"));
  await db.batch([
    db
      .prepare(
        "UPDATE join_requests SET status = 'rejected', decided_by = ?, decided_at = ?, note = ? WHERE id = ? AND status = 'pending'",
      )
      .bind(actor, now.toISOString(), note || null, request.id),
    auditStatement(
      db,
      { clubId: club.id, actorUserId: actor, action: "join.reject", entity: "user", entityKey: request.user_id, summary: note ? { note } : {} },
      now,
    ),
  ]);
  return c.json({ request: { id: request.id, status: "rejected" } });
});

/** Al entrar por otro lado (abierto, invitación), la solicitud pendiente queda contestada. */
export function closePendingStatement(db: D1Database, clubId: string, userId: string, now: Date) {
  return db
    .prepare(
      "UPDATE join_requests SET status = 'accepted', decided_at = ? WHERE club_id = ? AND user_id = ? AND status = 'pending'",
    )
    .bind(now.toISOString(), clubId, userId);
}
