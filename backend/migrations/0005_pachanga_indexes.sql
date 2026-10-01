-- La foto completa del pull lee cada tabla por `club_id`: sin índice, D1 recorre la tabla entera
-- (de todos los servidores) y gasta lecturas del plan gratuito en cada alta o reinstalación.
CREATE INDEX attendance_club ON attendance (club_id);
CREATE INDEX reports_club ON reports (club_id);
CREATE INDEX report_confirmations_club ON report_confirmations (club_id);
CREATE INDEX mvp_votes_club ON mvp_votes (club_id);
