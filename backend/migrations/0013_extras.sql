-- Extras de la 2.0 (§8): comprobar asistencia con el código de la jornada, y cupo con lista de espera.

-- Secreto del código de asistencia (TOTP). Lo pide el staff una vez; nunca viaja en el pull.
ALTER TABLE clubs ADD COLUMN checkin_secret TEXT;
-- Cuándo comprobó su asistencia con el código (null: no la comprobó).
ALTER TABLE attendance ADD COLUMN checked_in_at TEXT;
-- Cuándo dijo "Voy" (hora del servidor): el orden de la lista de espera.
ALTER TABLE attendance ADD COLUMN intent_at TEXT;
-- Cupo de la jornada (0 = sin límite).
ALTER TABLE matchdays ADD COLUMN max_players INTEGER NOT NULL DEFAULT 0 CHECK (max_players BETWEEN 0 AND 60);
