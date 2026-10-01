export type UserStatus = "active" | "suspended";

export type UserRecord = {
  id: string;
  username: string;
  displayName: string;
  passwordHash: string;
  isSuperadmin: boolean;
  status: UserStatus;
};

/** Lo que la API devuelve de un usuario. Nunca incluye el hash. */
export type PublicUser = Omit<UserRecord, "passwordHash">;

type UserRow = {
  id: string;
  username: string;
  display_name: string;
  password_hash: string;
  is_superadmin: number;
  status: UserStatus;
};

const COLUMNS = "id, username, display_name, password_hash, is_superadmin, status";

function fromRow(row: UserRow): UserRecord {
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    passwordHash: row.password_hash,
    isSuperadmin: row.is_superadmin === 1,
    status: row.status,
  };
}

export function toPublicUser({ passwordHash: _, ...user }: UserRecord): PublicUser {
  return user;
}

export async function findUserByUsername(db: D1Database, username: string) {
  const row = await db
    .prepare(`SELECT ${COLUMNS} FROM users WHERE username = ?`)
    .bind(username)
    .first<UserRow>();
  return row ? fromRow(row) : null;
}

export async function findUserById(db: D1Database, id: string) {
  const row = await db.prepare(`SELECT ${COLUMNS} FROM users WHERE id = ?`).bind(id).first<UserRow>();
  return row ? fromRow(row) : null;
}

export function insertUserStatement(
  db: D1Database,
  user: { id: string; username: string; displayName: string; passwordHash: string },
  now: Date,
) {
  const at = now.toISOString();
  return db
    .prepare(
      "INSERT INTO users (id, username, display_name, password_hash, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(user.id, user.username, user.displayName, user.passwordHash, at, at);
}

export function updatePasswordStatement(db: D1Database, userId: string, passwordHash: string, now: Date) {
  return db
    .prepare("UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?")
    .bind(passwordHash, now.toISOString(), userId);
}
