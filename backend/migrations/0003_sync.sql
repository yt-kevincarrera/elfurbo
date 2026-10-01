-- Temporadas y la infraestructura de sincronización (cambios por servidor y comandos aplicados).

CREATE TABLE seasons (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  name TEXT NOT NULL,
  start_date TEXT NOT NULL, -- YYYY-MM-DD
  is_active INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0, 1)),
  is_closed INTEGER NOT NULL DEFAULT 0 CHECK (is_closed IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK (NOT (is_active = 1 AND is_closed = 1))
);
CREATE INDEX seasons_club ON seasons (club_id);
-- Como mucho una temporada activa por servidor.
CREATE UNIQUE INDEX seasons_one_active ON seasons (club_id) WHERE is_active = 1;

-- Cada escritura deja aquí una fila por entidad tocada. Es lo que lee el pull.
CREATE TABLE changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  club_id TEXT NOT NULL,
  entity TEXT NOT NULL,
  entity_key TEXT NOT NULL,
  op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
  at TEXT NOT NULL
);
CREATE INDEX changes_club ON changes (club_id, id);

-- Hace los comandos idempotentes: un reintento devuelve el resultado guardado.
CREATE TABLE applied_commands (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  club_id TEXT NOT NULL,
  type TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('applied', 'rejected')),
  result TEXT NOT NULL,
  at TEXT NOT NULL
);
CREATE INDEX applied_commands_at ON applied_commands (at);

-- Los servidores aprobados antes de este PR reciben su temporada inicial (el año en curso).
INSERT INTO seasons (id, club_id, name, start_date, is_active, created_at, updated_at)
SELECT lower(hex(randomblob(16))), c.id, strftime('%Y', 'now'), strftime('%Y', 'now') || '-01-01', 1,
       strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  FROM clubs c
 WHERE c.status IN ('active', 'suspended')
   AND NOT EXISTS (SELECT 1 FROM seasons s WHERE s.club_id = c.id);
