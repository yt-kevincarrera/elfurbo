-- Perfil global (2.0 §5): si el jugador deja ver lo de sus servidores privados a quien no es
-- miembro de ellos. Por defecto sí (sin el nombre del servidor).
ALTER TABLE users ADD COLUMN show_private_stats INTEGER NOT NULL DEFAULT 1 CHECK (show_private_stats IN (0, 1));
