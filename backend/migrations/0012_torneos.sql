-- Torneos (2.0 §7). Un torneo es un servidor de tipo `tournament` (clubs.kind) organizado desde un
-- servidor anfitrión (clubs.host_club_id). Todo lleva `club_id` (el del torneo) y viaja en el pull.

CREATE TABLE tournaments (
  club_id TEXT PRIMARY KEY REFERENCES clubs (id),
  format TEXT NOT NULL CHECK (format IN ('league', 'cup', 'groups_cup')),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'registration', 'in_progress', 'finished')),
  rules TEXT NOT NULL DEFAULT '{}', -- JSON (ver backend/src/rules/tournament.ts)
  registration_closes_at TEXT,
  starts_on TEXT, -- YYYY-MM-DD
  max_teams INTEGER NOT NULL DEFAULT 16 CHECK (max_teams BETWEEN 2 AND 32),
  min_players INTEGER NOT NULL DEFAULT 5 CHECK (min_players BETWEEN 1 AND 30),
  max_players INTEGER NOT NULL DEFAULT 15 CHECK (max_players BETWEEN 1 AND 30),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE teams (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  name TEXT NOT NULL,
  short_name TEXT NOT NULL,
  color INTEGER NOT NULL DEFAULT 0 CHECK (color BETWEEN 0 AND 7),
  captain_member_id TEXT,
  represents_club_id TEXT REFERENCES clubs (id),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'withdrawn')),
  seed INTEGER,
  group_label TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX teams_club ON teams (club_id);

CREATE TABLE team_players (
  id TEXT PRIMARY KEY, -- team_id:member_id
  club_id TEXT NOT NULL,
  team_id TEXT NOT NULL REFERENCES teams (id),
  member_id TEXT NOT NULL,
  shirt INTEGER CHECK (shirt BETWEEN 0 AND 99),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'removed')),
  updated_at TEXT NOT NULL
);
CREATE INDEX team_players_club ON team_players (club_id);
-- Un jugador está como mucho en un equipo activo por torneo.
CREATE UNIQUE INDEX team_players_one_team ON team_players (club_id, member_id) WHERE status = 'active';

CREATE TABLE fixtures (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  stage TEXT NOT NULL CHECK (stage IN ('league', 'group', 'knockout', 'third')),
  round INTEGER NOT NULL,
  group_label TEXT,
  leg INTEGER NOT NULL DEFAULT 1,
  slot INTEGER,
  home_team_id TEXT,
  away_team_id TEXT,
  home_source TEXT, -- JSON {winnerOf} | {loserOf} | {group, pos}
  away_source TEXT,
  starts_at TEXT,
  place TEXT,
  scorer_member_id TEXT,
  status TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'played', 'cancelled', 'walkover')),
  home_score INTEGER CHECK (home_score BETWEEN 0 AND 99),
  away_score INTEGER CHECK (away_score BETWEEN 0 AND 99),
  home_pens INTEGER CHECK (home_pens BETWEEN 0 AND 99),
  away_pens INTEGER CHECK (away_pens BETWEEN 0 AND 99),
  walkover_winner TEXT,
  result_by TEXT,
  result_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX fixtures_club ON fixtures (club_id);

CREATE TABLE fixture_events (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL,
  fixture_id TEXT NOT NULL REFERENCES fixtures (id),
  team_id TEXT NOT NULL,
  member_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('goal', 'own_goal', 'yellow', 'red', 'mvp')),
  assist_member_id TEXT,
  minute INTEGER CHECK (minute BETWEEN 0 AND 200),
  updated_at TEXT NOT NULL
);
CREATE INDEX fixture_events_club ON fixture_events (club_id);
CREATE INDEX fixture_events_fixture ON fixture_events (fixture_id);

CREATE TABLE fixture_lineups (
  id TEXT PRIMARY KEY, -- fixture_id:member_id
  club_id TEXT NOT NULL,
  fixture_id TEXT NOT NULL REFERENCES fixtures (id),
  team_id TEXT NOT NULL,
  member_id TEXT NOT NULL
);
CREATE INDEX fixture_lineups_club ON fixture_lineups (club_id);
CREATE INDEX fixture_lineups_fixture ON fixture_lineups (fixture_id);

CREATE TABLE awards (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  kind TEXT NOT NULL CHECK (kind IN ('champion', 'runner_up', 'third', 'top_scorer', 'top_assists', 'best_player', 'fair_play')),
  team_id TEXT,
  member_id TEXT,
  value INTEGER,
  created_at TEXT NOT NULL
);
CREATE INDEX awards_club ON awards (club_id);

-- Invitación de equipo: al aceptarla se entra en el torneo y en ese equipo.
ALTER TABLE invites ADD COLUMN team_id TEXT REFERENCES teams (id);
