-- Las jornadas duran lo que quieran: la duración pasa a ser opcional (0 = se reportan goles desde
-- que empieza y el "voy" se marca hasta la hora de inicio). SQLite no deja cambiar un CHECK, así
-- que se rehace la tabla. Las claves foráneas de asistencia, reportes, confirmaciones y votos se
-- comprueban al final (diferidas): al renombrar, vuelven a apuntar a `matchdays`.
PRAGMA defer_foreign_keys = true;

CREATE TABLE matchdays_new (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  season_id TEXT NOT NULL REFERENCES seasons (id),
  starts_at TEXT NOT NULL,
  duration_minutes INTEGER NOT NULL DEFAULT 0 CHECK (duration_minutes BETWEEN 0 AND 600),
  place TEXT,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'cancelled', 'closed', 'reopened')),
  teams TEXT, -- JSON {"a": [memberId], "b": [memberId]} o NULL
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

INSERT INTO matchdays_new (id, club_id, season_id, starts_at, duration_minutes, place, notes, status, teams, created_by, created_at, updated_at)
  SELECT id, club_id, season_id, starts_at, duration_minutes, place, notes, status, teams, created_by, created_at, updated_at
    FROM matchdays;

DROP TABLE matchdays;
ALTER TABLE matchdays_new RENAME TO matchdays;

CREATE INDEX matchdays_club ON matchdays (club_id, starts_at);
CREATE INDEX matchdays_season ON matchdays (season_id);

PRAGMA defer_foreign_keys = false;
