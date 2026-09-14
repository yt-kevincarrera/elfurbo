# PR 1: Jornadas, duración, cierre, recurrencia y CRUD del admin

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convertir el "partido" en "jornada" con duración, estados de cierre automático/manual, creación recurrente, CRUD completo de jornadas y temporadas, borrado en cascada y guardarraíl del último admin.

**Architecture:** Los cambios de dominio viven en `lib/models/match_day.dart`, `lib/models/season.dart` y un nuevo `lib/domain/matchday_rules.dart` (Dart puro, testeable). El repositorio gana métodos de lote. La UI adapta lista, formulario, detalle y panel admin. Las reglas de Firestore hacen cumplir el cierre con `get()` de la jornada y `request.time`.

**Tech Stack:** Flutter 3.41, Riverpod 3, cloud_firestore 6, reglas Firestore v2, `flutter test`.

**Spec:** `docs/superpowers/specs/2026-09-14-jornadas-presencia-cierre-design.md` (secciones 1, 2, 5 y parte de 7).

## Global Constraints

- Colección y nombres internos se conservan: `matches`, `MatchDay`, `matchId`.
- Todo texto visible en tuteo (nunca voseo) y usando "jornada", no "partido".
- Duración por defecto: 120 minutos. Cierre automático: 72 horas desde `date`.
- Estados de jornada: `scheduled | cancelled | closed | reopened`.
- Paleta dorado/negro; no introducir verdes salvo estados semánticos.
- Cada tarea termina con `flutter analyze` sin issues y `flutter test` en verde.

---

### Task 1: Modelo `MatchDay` con duración y cierre

**Files:**
- Modify: `lib/models/match_day.dart`
- Test: `test/match_day_test.dart`

**Interfaces:**
- Produces: `MatchStatus { scheduled, cancelled, closed, reopened }`;
  `MatchDay.durationMinutes` (int, default 120); `DateTime get end`;
  `bool isUpcoming(DateTime now)`, `bool isInProgress(DateTime now)`,
  `bool isPlayed(DateTime now)`, `bool isClosed(DateTime now, {bool seasonClosed = false})`;
  `static const autoCloseAfter = Duration(hours: 72)`.

- [ ] **Step 1: Test que falla**

```dart
import 'package:elfurbo/models/match_day.dart';
import 'package:flutter_test/flutter_test.dart';

MatchDay _m(DateTime date, {MatchStatus status = MatchStatus.scheduled, int duration = 120}) =>
    MatchDay(id: 'm', date: date, seasonId: 's', status: status, createdBy: 'u', durationMinutes: duration);

void main() {
  final start = DateTime(2026, 9, 13, 10);
  test('próxima, en curso y jugada según duración', () {
    final m = _m(start);
    expect(m.isUpcoming(start.subtract(const Duration(hours: 1))), isTrue);
    expect(m.isInProgress(start.add(const Duration(minutes: 30))), isTrue);
    expect(m.isPlayed(start.add(const Duration(minutes: 30))), isFalse);
    expect(m.isPlayed(start.add(const Duration(minutes: 120))), isTrue);
    expect(m.end, start.add(const Duration(minutes: 120)));
  });
  test('cancelada no es próxima, en curso ni jugada', () {
    final m = _m(start, status: MatchStatus.cancelled);
    expect(m.isUpcoming(start.subtract(const Duration(days: 1))), isFalse);
    expect(m.isPlayed(start.add(const Duration(days: 1))), isFalse);
  });
  test('cierre automático a las 72 h, manual y reabierta', () {
    final m = _m(start);
    expect(m.isClosed(start.add(const Duration(hours: 71))), isFalse);
    expect(m.isClosed(start.add(const Duration(hours: 72))), isTrue);
    expect(_m(start, status: MatchStatus.closed).isClosed(start), isTrue);
    expect(_m(start, status: MatchStatus.reopened).isClosed(start.add(const Duration(days: 30))), isFalse);
    expect(m.isClosed(start, seasonClosed: true), isTrue);
  });
}
```

- [ ] **Step 2: Correr y ver fallar** — `flutter test test/match_day_test.dart` falla por `durationMinutes`/`isInProgress` indefinidos.

- [ ] **Step 3: Implementar** — en `match_day.dart`: enum con 4 estados; campo `durationMinutes` (default 120, leído de `d['durationMinutes']`); `end = date.add(Duration(minutes: durationMinutes))`; `isUpcoming = !isCancelled && now.isBefore(date)`; `isInProgress = !isCancelled && !now.isBefore(date) && now.isBefore(end)`; `isPlayed = !isCancelled && !now.isBefore(end)`; `isClosed` según spec; `isReopened`.

- [ ] **Step 4: Correr tests** — pasan. `flutter analyze` limpio.
- [ ] **Step 5: Commit** — `Modelo de jornada con duración, en curso y cierre`.

### Task 2: Modelo `Season` con cierre y reglas de recurrencia (dominio puro)

**Files:**
- Modify: `lib/models/season.dart`
- Create: `lib/domain/matchday_rules.dart`
- Test: `test/matchday_rules_test.dart`

**Interfaces:**
- Produces: `Season.isClosed` (bool, default false).
  `List<DateTime> weeklyDates(DateTime first, int weeks)` (weeks 1..26, devuelve `weeks` fechas separadas 7 días, misma hora).
  `bool canRemoveAdminRole(List<AppUser> users, String targetUid)` → false si el objetivo es el único admin activo.
  `bool canDeleteSeason(Season s, List<MatchDay> matches)` → false si alguna jornada tiene `seasonId == s.id`.

- [ ] **Step 1: Tests** para las tres funciones (semanas 1 devuelve solo la primera; 3 devuelve +7 y +14 días; `canRemoveAdminRole` false con un solo admin activo, true con dos; `canDeleteSeason` según jornadas).
- [ ] **Step 2: Ver fallar. Step 3: Implementar. Step 4: Verde. Step 5: Commit** — `Reglas de dominio: recurrencia semanal, último admin, borrar temporada`.

### Task 3: Repositorio: lotes y nuevos campos

**Files:**
- Modify: `lib/data/firestore_repo.dart`

**Interfaces:**
- Produces:
  - `createMatches({required List<DateTime> dates, required String seasonId, required String createdBy, required int durationMinutes, String? place, String? notes})` — un `WriteBatch` con un doc por fecha, `status: scheduled`, `durationMinutes`.
  - `updateMatch(id, {required DateTime date, required int durationMinutes, required String seasonId, String? place, String? notes})`.
  - `setMatchStatus(id, MatchStatus)` (ya existe; acepta closed/reopened).
  - `deleteMatchCascade(String matchId, {required Iterable<String> attendanceIds, required Iterable<String> reportIds, required Iterable<String> voteIds})` — batch que borra la jornada y todos los ids dados.
  - `updateSeason(id, {required String name, required DateTime startDate})`, `setSeasonClosed(id, bool)`, `deleteSeason(id)`, `moveMatchesToSeason(Iterable<String> matchIds, String seasonId)`.
- `createMatch` se elimina en favor de `createMatches` con una sola fecha.

- [ ] Implementar, `flutter analyze`, commit — `Repositorio: jornadas en lote, cascada y CRUD de temporadas`.

### Task 4: Providers derivados

**Files:**
- Modify: `lib/data/providers.dart`

**Interfaces:**
- Produces: `seasonByIdProvider` (`Provider.family<Season?, String>`);
  `matchClosedProvider` (`Provider.family<bool, String>`): `match.isClosed(now, seasonClosed: season?.isClosed ?? false)`;
  `activeSeasonProvider` ignora temporadas cerradas en el fallback;
  `seasonFilterLabelProvider` agrega " (cerrada)" si la temporada está cerrada;
  `lastAdminGuardProvider` no: se usa `canRemoveAdminRole` directo en la UI.

- [ ] Implementar, analyze, commit — `Providers de cierre de jornada y temporada`.

### Task 5: Lista de jornadas

**Files:**
- Modify: `lib/ui/matches/matches_screen.dart`

- [ ] Título "Jornadas", FAB "Nueva jornada", vacíos en tuteo con "jornada". Secciones: "Próximas" = `!isPlayed(now)` (incluye en curso y canceladas futuras) ordenadas ascendente; "Jugadas" = resto, descendente. Tarjeta próxima muestra "En curso" si `isInProgress`, y tachada + "Cancelada" si cancelada (sin botones de asistencia). Tarjeta jugada muestra candado "Cerrada" si `matchClosedProvider`.
- [ ] Analyze, commit — `Lista de jornadas con en curso, canceladas por fecha y cierre`.

### Task 6: Formulario de jornada

**Files:**
- Modify: `lib/ui/matches/match_form_sheet.dart`

- [ ] Campos nuevos: duración (SegmentedButton 60/90/120/180 min + fallback al valor existente), temporada (DropdownMenu con temporadas no cerradas, default activa; si no hay ninguna, se crea "Temporada AAAA" como hoy), y solo al crear: "Repetir cada semana" (Switch) con "Semanas" (Slider 2..26). Guardar llama `createMatches(dates: weeklyDates(_date, weeks))` o `updateMatch(...)`. Textos: "Nueva jornada", "Editar jornada", "Crear N jornadas".
- [ ] Analyze, commit — `Formulario de jornada: duración, temporada y repetición semanal`.

### Task 7: Detalle de jornada: cierre, cascada y textos

**Files:**
- Modify: `lib/ui/matches/match_detail_screen.dart`, `attendance_tab.dart`, `reports_tab.dart`, `mvp_tab.dart`, `teams_tab.dart`, `summary_tab.dart`

- [ ] Detalle: menú admin con "Cerrar jornada" (si abierta) / "Reabrir jornada" (si cerrada) → `setMatchStatus(closed|reopened)`; "Eliminar" usa `deleteMatchCascade` con ids tomados de `attendanceForMatchProvider`, `reportsForMatchProvider`, `votesForMatchProvider`. Banner "Jornada cerrada: ya no se pueden cargar goles, confirmar ni votar." cuando `matchClosedProvider`. Subtítulo muestra "En curso" si corresponde.
- [ ] Pestañas: reciben `closed` (bool) y deshabilitan escritura: asistencia (segmented y pulsación larga), goles (Cargar/Editar/Borrar/Es verdad/decisiones admin salvo "Quitar decisión" que también se bloquea), MVP (radio y quitar voto), equipos (Armar/Guardar/Borrar). Textos "partido" → "jornada".
- [ ] Analyze, commit — `Detalle de jornada: cerrar, reabrir, eliminar en cascada`.

### Task 8: Panel admin: temporadas y último admin

**Files:**
- Modify: `lib/ui/admin/admin_screen.dart`

- [ ] Temporadas: menú con "Marcar como activa" (solo si no cerrada), "Renombrar", "Editar fecha de inicio" (date picker → `updateSeason`), "Cerrar temporada"/"Reabrir temporada" (`setSeasonClosed`), "Eliminar" (si `canDeleteSeason` → confirm → `deleteSeason`; si no, diálogo "Mover N jornadas a…" con lista de otras temporadas → `moveMatchesToSeason` y luego borrar). Subtítulo con "· cerrada".
- [ ] Jugadores: ocultar "Quitar admin" y "Bloquear" cuando `!canRemoveAdminRole(users, u.uid)`; mostrar tooltip "Es el único admin".
- [ ] Analyze, commit — `Admin: CRUD de temporadas y guardarraíl del último admin`.

### Task 9: Reglas de Firestore

**Files:**
- Modify: `firestore.rules`

- [ ] Agregar:

```
function matchData(matchId) {
  return get(/databases/$(db)/documents/matches/$(matchId)).data;
}
function seasonClosed(seasonId) {
  return seasonId != ''
    && exists(/databases/$(db)/documents/seasons/$(seasonId))
    && get(/databases/$(db)/documents/seasons/$(seasonId)).data.get('isClosed', false) == true;
}
// Jornada abierta: no cancelada ni cerrada, dentro de las 72 h (o reabierta) y temporada abierta.
function matchOpen(matchId) {
  let m = matchData(matchId);
  return m.status != 'cancelled' && m.status != 'closed'
    && (m.status == 'reopened' || request.time < m.date + duration.value(72, 'h'))
    && !seasonClosed(m.seasonId);
}
function matchPlayed(matchId) {
  let m = matchData(matchId);
  return request.time >= m.date + duration.value(m.get('durationMinutes', 120), 'm');
}
```

  - `matches` create/update: `status in ['scheduled','cancelled','closed','reopened']`, `durationMinutes is int && >= 30 && <= 600`.
  - `attendance` create/update propio: `matchOpen(matchId)`.
  - `reports` create/update propio y confirmación de compañero: `matchOpen` y `matchPlayed`. Delete propio: `matchOpen`.
  - `mvpVotes` create/update/delete propio: `matchOpen` y `matchPlayed`.
  - El admin sigue con `allow write/update/delete: if isAdmin()` (puede corregir en jornadas cerradas; la UI lo frena salvo reabrir).
- [ ] `firebase --project elfurbo-2ba0c deploy --only firestore:rules`. Commit — `Reglas: cierre de jornada y temporada, validación de estados y duración`.

### Task 10: Textos, README, Functions y verificación

**Files:**
- Modify: todos los `.dart` con "partido"/"Partido", `functions/index.js` (notificaciones), `README.md`.

- [ ] Reemplazar "partido(s)" por "jornada(s)" en textos visibles y notificaciones (no en identificadores). Revisar concordancias de género ("el partido" → "la jornada", "primer partido" → "primera jornada", "Nuevo partido" → "Nueva jornada"). Mantener "partidos jugados" como métrica en la tabla y perfil: se cambia a "jornadas jugadas".
- [ ] `flutter analyze`, `flutter test`, `flutter build apk --release --split-per-abi`, instalar en el Pixel, probar: crear jornada recurrente, ver "En curso", cerrar/reabrir, eliminar en cascada, cerrar temporada, no poder quitar el último admin.
- [ ] Commit — `Jornadas en todos los textos y documentación`. Abrir PR contra `main`.
