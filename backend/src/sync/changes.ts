/** Entidades que viajan en el pull. */
export type SyncEntity =
  | "club"
  | "member"
  | "season"
  | "matchday"
  | "attendance"
  | "report"
  | "confirmation"
  | "vote"
  | "tournament"
  | "team"
  | "teamPlayer"
  | "fixture"
  | "fixtureEvent"
  | "fixtureLineup"
  | "award";

export type Touch = { entity: SyncEntity; key: string; op: "upsert" | "delete" };

/** Una fila de `changes`, para meterla en el mismo `batch` que la escritura. */
export function changeStatement(db: D1Database, clubId: string, touch: Touch, now: Date) {
  return db
    .prepare("INSERT INTO changes (club_id, entity, entity_key, op, at) VALUES (?, ?, ?, ?, ?)")
    .bind(clubId, touch.entity, touch.key, touch.op, now.toISOString());
}

export const upsert = (entity: SyncEntity, key: string): Touch => ({ entity, key, op: "upsert" });
export const remove = (entity: SyncEntity, key: string): Touch => ({ entity, key, op: "delete" });
