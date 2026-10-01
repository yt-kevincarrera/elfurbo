import { normalizeCode, randomCode, sha256Hex } from "./crypto";

const CODE_HOURS = 24;

/**
 * Prepara un código de recuperación nuevo para `userId`. Anula los anteriores sin usar, para que
 * solo valga el último que se le pasó por WhatsApp. El código en claro solo se devuelve aquí.
 */
export async function issueRecoveryCode(db: D1Database, userId: string, createdBy: string, now: Date) {
  const code = randomCode();
  const expiresAt = new Date(now.getTime() + CODE_HOURS * 60 * 60 * 1000).toISOString();
  const statements = [
    db
      .prepare("UPDATE recovery_codes SET used_at = ? WHERE user_id = ? AND used_at IS NULL")
      .bind(now.toISOString(), userId),
    db
      .prepare(
        "INSERT INTO recovery_codes (id, user_id, code_hash, created_by, expires_at) VALUES (?, ?, ?, ?, ?)",
      )
      .bind(crypto.randomUUID(), userId, await sha256Hex(normalizeCode(code)), createdBy, expiresAt),
  ];
  return { code: `${code.slice(0, 4)}-${code.slice(4)}`, expiresAt, statements };
}
