-- Pedir entrar en un servidor público (2.0 §6). Una sola pendiente por persona y servidor.
CREATE TABLE join_requests (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  message TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'rejected', 'cancelled')),
  decided_by TEXT,
  note TEXT,
  created_at TEXT NOT NULL,
  decided_at TEXT
);
CREATE UNIQUE INDEX join_requests_pending ON join_requests (club_id, user_id) WHERE status = 'pending';
CREATE INDEX join_requests_club ON join_requests (club_id, status);
CREATE INDEX join_requests_user ON join_requests (user_id, status);
