-- MVP a dedo: si la votación cierra sin votos, un admin elige el MVP de la jornada.
-- Los votos ganan siempre: si alguien vota (p. ej. al reabrirla), esto se ignora.

-- Miembro elegido (null: nadie).
ALTER TABLE matchdays ADD COLUMN mvp_pick TEXT;
-- El admin que lo eligió (puede ser él mismo: se enseña en la app).
ALTER TABLE matchdays ADD COLUMN mvp_pick_by TEXT;
