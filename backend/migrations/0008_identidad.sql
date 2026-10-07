-- Identidad y visibilidad de un servidor (2.0): tipo (grupo o torneo), privado o público, oficial,
-- provincia, ciudad, color y, para los torneos, su servidor anfitrión. Todo con valores por
-- defecto: los servidores de la 1.x quedan como grupos privados, sin cambiar nada.

ALTER TABLE clubs ADD COLUMN kind TEXT NOT NULL DEFAULT 'group' CHECK (kind IN ('group', 'tournament'));
ALTER TABLE clubs ADD COLUMN visibility TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'public'));
ALTER TABLE clubs ADD COLUMN official INTEGER NOT NULL DEFAULT 0 CHECK (official IN (0, 1));
ALTER TABLE clubs ADD COLUMN province TEXT;
ALTER TABLE clubs ADD COLUMN city TEXT;
ALTER TABLE clubs ADD COLUMN color INTEGER NOT NULL DEFAULT 0 CHECK (color BETWEEN 0 AND 7);
ALTER TABLE clubs ADD COLUMN host_club_id TEXT REFERENCES clubs (id);
-- El superadmin lo sacó del directorio: su dueño ya no lo puede volver a hacer público.
ALTER TABLE clubs ADD COLUMN delisted INTEGER NOT NULL DEFAULT 0 CHECK (delisted IN (0, 1));

-- El directorio lee los públicos y activos.
CREATE INDEX clubs_directory ON clubs (visibility, status);
CREATE INDEX clubs_host ON clubs (host_club_id);
