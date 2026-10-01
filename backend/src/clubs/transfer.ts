import { errors } from "../http/errors";
import { upsert, type Touch } from "../sync/changes";
import { findMember, type ClubRecord } from "./model";

/**
 * Transferir la propiedad: el dueño actual pasa a admin y `memberId` (miembro activo con cuenta)
 * pasa a dueño. Lo usan el superadmin (endpoint) y el propio dueño (comando de sync).
 */
export async function transferOwnership(db: D1Database, club: ClubRecord, memberId: string, now: Date) {
  const target = await findMember(db, club.id, memberId);
  if (!target || target.status !== "active" || !target.userId) {
    throw errors.invalidInput({ memberId: ["Tiene que ser un miembro activo con cuenta"] });
  }
  if (target.role === "owner") throw errors.invalidState("Ese miembro ya es el dueño");
  const current = await db
    .prepare("SELECT id FROM members WHERE club_id = ? AND role = 'owner'")
    .bind(club.id)
    .first<{ id: string }>();
  const at = now.toISOString();
  const statements = [
    db.prepare("UPDATE members SET role = 'admin', updated_at = ? WHERE club_id = ? AND role = 'owner'").bind(at, club.id),
    db.prepare("UPDATE members SET role = 'owner', updated_at = ? WHERE id = ?").bind(at, target.id),
    db.prepare("UPDATE clubs SET owner_user_id = ?, updated_at = ? WHERE id = ?").bind(target.userId, at, club.id),
  ];
  const touched: Touch[] = [upsert("member", target.id), upsert("club", club.id)];
  if (current) touched.push(upsert("member", current.id));
  return { statements, touched, target };
}
