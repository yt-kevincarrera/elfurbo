-- Estadísticas y prestigio calculados en el servidor (2.0 §3 y §4). Las escribe el job del cron;
-- nadie más las toca. Período = una temporada (servidores) o el torneo entero (torneos).

CREATE TABLE member_stats (
  club_id TEXT NOT NULL,
  period_id TEXT NOT NULL,
  member_id TEXT NOT NULL,
  played INTEGER NOT NULL DEFAULT 0,
  goals INTEGER NOT NULL DEFAULT 0,
  assists INTEGER NOT NULL DEFAULT 0,
  mvps INTEGER NOT NULL DEFAULT 0,
  hat_tricks INTEGER NOT NULL DEFAULT 0,
  best_streak INTEGER NOT NULL DEFAULT 0,
  best_day_goals INTEGER NOT NULL DEFAULT 0,
  reports INTEGER NOT NULL DEFAULT 0,
  rejected INTEGER NOT NULL DEFAULT 0,
  checkins INTEGER NOT NULL DEFAULT 0,
  yellows INTEGER NOT NULL DEFAULT 0,
  reds INTEGER NOT NULL DEFAULT 0,
  -- Promedio fuera de lo normal en su servidor (se muestra, no se borra nada).
  flag INTEGER NOT NULL DEFAULT 0 CHECK (flag IN (0, 1)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (club_id, period_id, member_id)
);
CREATE INDEX member_stats_member ON member_stats (member_id);

CREATE TABLE club_metrics (
  club_id TEXT PRIMARY KEY,
  -- Hasta qué cambio (`changes.id`) de este servidor está calculado.
  computed_through INTEGER NOT NULL DEFAULT 0,
  computed_at TEXT NOT NULL,
  tier TEXT NOT NULL CHECK (tier IN ('official', 'verified', 'established', 'casual', 'new')),
  score INTEGER NOT NULL,
  signals TEXT NOT NULL, -- JSON
  play_days TEXT NOT NULL DEFAULT '[]', -- JSON: días de la semana (1 = lunes … 7 = domingo)
  active_players INTEGER NOT NULL DEFAULT 0,
  last_played_at TEXT
);

-- El nivel con que se jugó cada período. Al cerrarlo se congela (`frozen_at`).
CREATE TABLE period_tiers (
  club_id TEXT NOT NULL,
  period_id TEXT NOT NULL,
  tier TEXT NOT NULL CHECK (tier IN ('official', 'verified', 'established', 'casual', 'new')),
  score INTEGER NOT NULL,
  frozen_at TEXT,
  PRIMARY KEY (club_id, period_id)
);
