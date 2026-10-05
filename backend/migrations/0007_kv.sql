-- Valores sueltos del Worker: la última release de GitHub (caché de 1 hora), hasta dónde se
-- purgó `changes` y, más adelante, el token de acceso de FCM.

CREATE TABLE kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  expires_at INTEGER -- milisegundos desde 1970; null = no caduca
);
