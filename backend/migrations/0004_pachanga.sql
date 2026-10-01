-- La pachanga: jornadas, asistencia, reportes de goles y asistencias, confirmaciones y votos de MVP.
-- Las tablas por persona tienen un `id` compuesto ("jornada:miembro") para que el pull las lea por
-- clave como al resto de entidades. Todas las referencias a personas son `members.id`.

CREATE TABLE matchdays (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  season_id TEXT NOT NULL REFERENCES seasons (id),
  starts_at TEXT NOT NULL,
  duration_minutes INTEGER NOT NULL DEFAULT 120 CHECK (duration_minutes BETWEEN 30 AND 600),
  place TEXT,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'cancelled', 'closed', 'reopened')),
  teams TEXT, -- JSON {"a": [memberId], "b": [memberId]} o NULL
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX matchdays_club ON matchdays (club_id, starts_at);
CREATE INDEX matchdays_season ON matchdays (season_id);

CREATE TABLE attendance (
  id TEXT PRIMARY KEY, -- matchday_id:member_id
  club_id TEXT NOT NULL,
  matchday_id TEXT NOT NULL REFERENCES matchdays (id),
  member_id TEXT NOT NULL,
  intent TEXT CHECK (intent IN ('yes', 'no', 'maybe')),
  played INTEGER CHECK (played IN (0, 1)),
  played_set_by TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX attendance_matchday ON attendance (matchday_id);

CREATE TABLE reports (
  id TEXT PRIMARY KEY, -- matchday_id:member_id
  club_id TEXT NOT NULL,
  matchday_id TEXT NOT NULL REFERENCES matchdays (id),
  member_id TEXT NOT NULL,
  goals INTEGER NOT NULL CHECK (goals BETWEEN 0 AND 30),
  assists INTEGER NOT NULL CHECK (assists BETWEEN 0 AND 30),
  note TEXT,
  loaded_by TEXT NOT NULL,
  decision TEXT CHECK (decision IN ('confirmed', 'rejected')),
  corrected_by TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX reports_matchday ON reports (matchday_id);

-- Tabla aparte (no una lista dentro del reporte) para que confirmar sin conexión nunca choque.
CREATE TABLE report_confirmations (
  id TEXT PRIMARY KEY, -- matchday_id:member_id:confirmer_id
  club_id TEXT NOT NULL,
  matchday_id TEXT NOT NULL REFERENCES matchdays (id),
  member_id TEXT NOT NULL,
  confirmer_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX report_confirmations_matchday ON report_confirmations (matchday_id, member_id);

CREATE TABLE mvp_votes (
  id TEXT PRIMARY KEY, -- matchday_id:voter_id
  club_id TEXT NOT NULL,
  matchday_id TEXT NOT NULL REFERENCES matchdays (id),
  voter_id TEXT NOT NULL,
  voted_for TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK (voter_id <> voted_for)
);
CREATE INDEX mvp_votes_matchday ON mvp_votes (matchday_id);
