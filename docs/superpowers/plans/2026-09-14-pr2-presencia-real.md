# PR 2: Presencia real y pasar lista

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separar la intención de asistir ("Voy") de la presencia real ("Jugué") para que partidos jugados, rachas, logros, valoraciones, candidatos a MVP y permisos de confirmar/votar usen solo la presencia.

**Architecture:** El documento `attendance` gana `played` (bool?) y `playedSetBy`. `Attendance.isPresent` centraliza la lectura. `StatsEngine` y las pestañas dejan de mirar `status == yes` una vez jugada la jornada. El admin pasa lista desde una hoja con todos los jugadores. Las reglas exigen jornada jugada y abierta para escribir `played` y usan la presencia para confirmar y votar.

**Tech Stack:** Flutter 3.41, Riverpod 3, cloud_firestore 6, reglas Firestore v2.

**Spec:** `docs/superpowers/specs/2026-09-14-jornadas-presencia-cierre-design.md` sección 3. Depende del PR 1 (`feature/jornadas-cierre-crud`).

## Global Constraints

- Tuteo, "jornada". Paleta dorado/negro.
- Antes de jugarse la jornada, `status` (intención) sigue mandando para "van" y Equipos.
- Una vez jugada, solo `played == true` (o reporte confirmado) cuenta como presencia.

---

### Task 1: Modelo `Attendance` con presencia

**Files:** Modify `lib/models/attendance.dart`. Test `test/attendance_test.dart`.

**Interfaces:** `Attendance.played` (bool?), `Attendance.playedSetBy` (String?), `bool get isPresent => played == true`, `bool get isAbsent => played == false`, `bool get presenceUnknown => played == null`, `static const fieldPlayed = 'played'`.

- [ ] Test: `fromDoc` sin `played` → `presenceUnknown`; con `played: true` → `isPresent`; `playedSetBy` se lee.
- [ ] Implementar. Verde. Commit.

### Task 2: `StatsEngine` con presencia real

**Files:** Modify `lib/domain/stats_engine.dart`, `test/stats_engine_test.dart`.

- [ ] Cambiar `attendeesByMatch`: incluir `a.uid` solo si `a.isPresent`. Actualizar el comentario de clase. Ajustar fixtures del test existente (`status: yes` → `played: true`) y agregar test: un jugador con `status: yes` y `played: null` no cuenta como jugado; con `played: false` tampoco aunque tenga `status: yes`.
- [ ] Verde. Commit.

### Task 3: Repositorio

**Files:** Modify `lib/data/firestore_repo.dart`.

**Interfaces:**
- `setPresence(String matchId, String uid, bool played, {required String setBy})` → `set(..., merge: true)` de `{matchId, uid, played, playedSetBy, updatedAt}`.
- `setPresenceBulk(String matchId, Map<String, bool> presenceByUid, {required String setBy})` → lote con `set(merge: true)`.
- `submitReport` también escribe `played: true, playedSetBy: uid` en la asistencia (misma hoja, dos escrituras, ya se hace con `setAttendance`; se reemplaza por `setPresence`).

- [ ] Implementar. Commit.

### Task 4: Providers de presencia

**Files:** Modify `lib/data/providers.dart`.

**Interfaces:**
- `presentUidsProvider` (`Provider.family<Set<String>, String>`): uids con `isPresent` para la jornada.
- `iAmPresentProvider` (`Provider.family<bool, String>`).

- [ ] Implementar. Commit.

### Task 5: Pestaña Asistencia

**Files:** Modify `lib/ui/matches/attendance_tab.dart`.

- [ ] Si la jornada ya se jugó: tarjeta "¿Jugaste esta jornada?" con botones "Jugué" / "No fui" que escriben `setPresence`. Grupos: "Jugaron" (`isPresent`), "No fueron" (`isAbsent`), "Sin confirmar" (resto, mostrando su intención previa entre paréntesis: "dijo que iba"). Si no se jugó: comportamiento actual con intención.
- [ ] Admin, jornada jugada: botón "Pasar lista" que abre hoja con `CheckboxListTile` por jugador activo, prellenado con `isPresent` o, si `presenceUnknown`, con `status == yes`; "Guardar" llama `setPresenceBulk` con true/false para todos.
- [ ] Commit.

### Task 6: Pestañas Goles, MVP, Equipos y lista

**Files:** Modify `reports_tab.dart`, `mvp_tab.dart`, `teams_tab.dart`, `matches_screen.dart`, `summary_tab.dart`.

- [ ] Goles: `iPlayed = ref.watch(iAmPresentProvider(match.id))`; texto "Para confirmar a otros tienes que marcar Jugué en Asistencia". El formulario de reporte llama `setPresence(true)`.
- [ ] MVP: candidatos = `presentUidsProvider` menos yo; `iPlayed` igual que arriba.
- [ ] Equipos: si la jornada no se jugó, usa `status == yes` (como hoy); si se jugó, usa presencia.
- [ ] Lista jugadas: `iPlayed` = presencia. Resumen: `summary.players` ya usa el motor.
- [ ] Commit.

### Task 7: Reglas

**Files:** Modify `firestore.rules`.

- [ ] `attendedYes` → `isPresent(matchId, uid)`: `get(attendance).data.get('played', false) == true`. Confirmar reporte y votar exigen `isPresent` del actor; votar también exige `isPresent(matchId, votedFor)`.
- [ ] Asistencia propia: si `request.resource.data.get('played', null) != null` entonces `matchPlayed(matchId)` y `request.resource.data.playedSetBy == request.auth.uid`. Cambiar `status` solo se permite si no se jugó (`!matchPlayed`), salvo que venga con `played` (el caso de reportar goles, que escribe `played: true` y conserva `status`).
- [ ] Desplegar. Commit.

### Task 8: Functions y verificación

- [ ] `attendeesYes` en `functions/index.js` → `attendeesPresent`: `where('played', '==', true)`. El recordatorio de las 22:00 sigue usando intención `yes` (todavía nadie confirmó presencia): se mantiene una función `intendedYes` para ese caso.
- [ ] `flutter analyze`, `flutter test`, build, prueba en Pixel: marcar Jugué, pasar lista, ver que la tabla solo cuente presentes.
- [ ] Commit, push, PR (base: `feature/jornadas-cierre-crud`).
