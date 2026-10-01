-- Servidores (en el código, `clubs`), miembros, invitaciones y registro de auditoría.

CREATE TABLE clubs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'rejected', 'suspended')),
  owner_user_id TEXT NOT NULL,
  request_note TEXT NOT NULL DEFAULT '',
  review_note TEXT,
  reviewed_by TEXT,
  reviewed_at TEXT,
  settings TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX clubs_owner ON clubs (owner_user_id);
CREATE INDEX clubs_status ON clubs (status);

-- La identidad que acumula estadísticas dentro de un servidor. Sin cuenta = `guest` con
-- `user_id` NULL; reclamar el perfil es rellenar `user_id` y pasar a `player`.
CREATE TABLE members (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  user_id TEXT,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'scorer', 'player', 'guest')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'left', 'banned')),
  display_name TEXT NOT NULL,
  nickname TEXT,
  created_by TEXT,
  claimed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK ((role = 'guest') = (user_id IS NULL))
);
CREATE UNIQUE INDEX members_club_user ON members (club_id, user_id) WHERE user_id IS NOT NULL;
CREATE INDEX members_user ON members (user_id);
CREATE INDEX members_club ON members (club_id);

CREATE TABLE invites (
  code TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  role TEXT NOT NULL CHECK (role IN ('player', 'scorer', 'admin')),
  target_member_id TEXT REFERENCES members (id),
  max_uses INTEGER NOT NULL CHECK (max_uses BETWEEN 1 AND 100),
  uses INTEGER NOT NULL DEFAULT 0,
  expires_at TEXT NOT NULL,
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);
CREATE INDEX invites_club ON invites (club_id);

CREATE TABLE audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  club_id TEXT,
  actor_user_id TEXT NOT NULL,
  action TEXT NOT NULL,
  entity TEXT NOT NULL,
  entity_key TEXT NOT NULL,
  summary TEXT NOT NULL DEFAULT '{}',
  at TEXT NOT NULL
);
CREATE INDEX audit_club ON audit_log (club_id, id);
