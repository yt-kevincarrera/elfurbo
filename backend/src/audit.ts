export type AuditEntry = {
  clubId: string | null;
  actorUserId: string;
  action: string;
  entity: string;
  entityKey: string;
  summary?: Record<string, unknown>;
};

/** Una fila del registro de auditoría, para meterla en el mismo `batch` que el cambio. */
export function auditStatement(db: D1Database, entry: AuditEntry, now: Date) {
  return db
    .prepare(
      "INSERT INTO audit_log (club_id, actor_user_id, action, entity, entity_key, summary, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(
      entry.clubId,
      entry.actorUserId,
      entry.action,
      entry.entity,
      entry.entityKey,
      JSON.stringify(entry.summary ?? {}),
      now.toISOString(),
    );
}
