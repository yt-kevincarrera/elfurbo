import { z } from "zod";
import { canActForOthers } from "../authz";
import { errors } from "../http/errors";
import { upsert } from "../sync/changes";
import { command } from "../sync/command";

const displayName = z.string().trim().min(1, { error: "Escribe un nombre" }).max(40);
const nickname = z.string().trim().max(30).nullable();

/** Jugador sin cuenta (el primo de alguien). El id lo genera la app, para poder cargarle datos offline. */
export const createGuest = command(
  z.object({ id: z.uuid(), displayName, nickname: nickname.optional() }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const at = ctx.now.toISOString();
    return {
      statements: [
        ctx.db
          .prepare(
            `INSERT INTO members (id, club_id, user_id, role, display_name, nickname, created_by, created_at, updated_at)
             VALUES (?, ?, NULL, 'guest', ?, ?, ?, ?, ?)`,
          )
          .bind(p.id, ctx.club.id, p.displayName, p.nickname ?? null, ctx.user.id, at, at),
      ],
      touched: [upsert("member", p.id)],
    };
  },
);
