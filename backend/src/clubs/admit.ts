import { auditStatement } from "../audit";
import { errors } from "../http/errors";
import { changeStatement, upsert } from "../sync/changes";
import { findMemberByUser } from "./model";

/**
 * Lo que hace falta para que `user` entre en un servidor como `player` (al pedir entrar en uno
 * abierto, o cuando un admin acepta su solicitud): un perfil nuevo o, si ya estuvo y se fue, el
 * mismo de antes con sus estadísticas. Lanza si ya es miembro o si lo expulsaron.
 */
export async function admitStatements(
  db: D1Database,
  clubId: string,
  user: { id: string; displayName: string },
  actorUserId: string,
  action: string,
  now: Date,
) {
  const at = now.toISOString();
  const existing = await findMemberByUser(db, clubId, user.id);
  if (existing?.status === "banned") throw errors.bannedFromClub();
  if (existing?.status === "active") throw errors.alreadyMember();
  const memberId = existing?.id ?? crypto.randomUUID();
  const statements = existing
    ? [
        db
          .prepare("UPDATE members SET status = 'active', role = 'player', updated_at = ? WHERE id = ? AND status = 'left'")
          .bind(at, memberId),
      ]
    : [
        db
          .prepare(
            `INSERT INTO members (id, club_id, user_id, role, display_name, created_by, created_at, updated_at)
             VALUES (?, ?, ?, 'player', ?, ?, ?, ?)`,
          )
          .bind(memberId, clubId, user.id, user.displayName, actorUserId, at, at),
      ];
  statements.push(
    changeStatement(db, clubId, upsert("member", memberId), now),
    auditStatement(db, { clubId, actorUserId, action, entity: "member", entityKey: memberId }, now),
  );
  return { memberId, statements };
}
