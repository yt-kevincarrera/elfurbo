# PR 3: Reportes (rechazo definitivo, corrección del admin, aviso de edición) y desempate de MVP

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el rechazo del admin sea definitivo, que el admin pueda corregir números, que editar un reporte confirmado avise a los presentes, y que los empates de MVP se desempaten por goles y asistencias del día.

**Architecture:** `MatchReport` gana `correctedBy`. `StatsEngine.mvpWinners` acepta los reportes confirmados de la jornada para desempatar. El repositorio gana `adminCorrectReport`. La UI de Goles oculta editar/borrar al autor de un reporte rechazado y da "Corregir" al admin. Las reglas bloquean al autor sobre un reporte rechazado. La Function `onReportUpdated` avisa cuando un confirmado vuelve a pendiente.

**Tech Stack:** Flutter 3.41, Riverpod 3, cloud_firestore 6, reglas Firestore v2, Functions v2.

**Spec:** `docs/superpowers/specs/2026-09-14-jornadas-presencia-cierre-design.md` sección 4. Depende del PR 2 (`feature/presencia-real`).

## Global Constraints

- Tuteo, "jornada". Paleta dorado/negro.

---

### Task 1: `MatchReport.correctedBy` y desempate de MVP (dominio)

**Files:** Modify `lib/models/match_report.dart`, `lib/domain/stats_engine.dart`. Test `test/report_mvp_test.dart`.

**Interfaces:**
- `MatchReport.correctedBy` (String?), `bool get correctedByAdmin => correctedBy != null`.
- `static List<String> mvpWinners(List<MvpVote> votes, {Map<String, MatchReport> confirmedReports = const {}})`: máximo de votos; empate → mayor `goals` del reporte confirmado (0 si no tiene); luego mayor `assists`; si persiste, todos ordenados.
- `StatsEngine` pasa a `mvpWinners` los reportes confirmados de cada jornada.

- [ ] Tests: sin empate gana el más votado; empate 1-1 gana quien tiene más goles confirmados; con goles iguales gana más asistencias; todo igual comparten; un reporte pendiente no desempata. `fromDoc` lee `correctedBy`.
- [ ] Implementar. Verde. Commit.

### Task 2: Repositorio

**Files:** Modify `lib/data/firestore_repo.dart`.

**Interfaces:** `adminCorrectReport(String reportId, {required int goals, required int assists, required String correctedBy})` → `update({goals, assists, adminStatus: 'confirmed', correctedBy, updatedAt})`.

- [ ] Implementar. Commit.

### Task 3: UI de Goles

**Files:** Modify `lib/ui/matches/reports_tab.dart`, `lib/ui/widgets/common.dart`.

- [ ] Tarjeta "Tu reporte": si `myReport.isRejected` no muestra Editar ni Borrar y explica "El admin rechazó este reporte. Solo el admin puede reabrirlo." El chip muestra "Corregido (admin)" cuando `correctedByAdmin`.
- [ ] Tile de compañero (admin): botón "Corregir" que abre `showReportFormSheet(..., existing: r, correctFor: r.uid)`; en ese modo el formulario titula "Corregir reporte de X" y guarda con `adminCorrectReport`. Sin marcar presencia del admin.
- [ ] Commit.

### Task 4: UI de MVP

**Files:** Modify `lib/ui/matches/mvp_tab.dart`.

- [ ] `winners = StatsEngine.mvpWinners(votes, confirmedReports: {for (r in reports.where(isConfirmed)) r.uid: r})`. Texto: "si hay empate, desempata por goles y asistencias confirmados del día; si sigue igual, comparten".
- [ ] Commit.

### Task 5: Reglas

**Files:** Modify `firestore.rules`.

- [ ] En `reports`, edición y borrado propios agregan `&& resource.data.get('adminStatus', null) != 'rejected'`.
- [ ] Desplegar. Commit.

### Task 6: Functions

**Files:** Modify `functions/index.js`.

- [ ] `onReportUpdated`: si `prev == 'confirmed' && next == 'pending'`, avisar a `attendeesPresent(matchId)` menos el autor: título "Reporte editado", cuerpo "X cambió su reporte a N goles y M asistencias. Vuelve a confirmarlo." Si el admin corrigió (`after.correctedBy` cambió), avisar al autor "El admin corrigió tu reporte: N goles y M asistencias."
- [ ] Commit, analyze, test, build, PR (base `feature/presencia-real`).
