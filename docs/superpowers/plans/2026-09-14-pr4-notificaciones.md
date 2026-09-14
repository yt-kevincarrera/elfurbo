# PR 4: Notificaciones (tokens, canal, navegación, recordatorios y chequeos sin Blaze)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que las notificaciones no se filtren entre usuarios de un mismo teléfono, abran la pantalla correcta al tocarlas, tengan canal propio, y que sin Blaze la app avise localmente de jugadores pendientes, reportes por confirmar y recordatorios de jornada.

**Architecture:** Un servicio único `LocalNotifications` (canales, mostrar, programar, payload JSON, detalles de arranque). Un `NotificationRouter` que traduce el payload a navegación con un `GlobalKey<NavigatorState>` global y un `ValueNotifier` para cambiar la pestaña del shell. `PushService` pasa a `fcmTokens` (array) y se da de baja al cerrar sesión. El worker de WorkManager, además de buscar actualizaciones, inicializa Firebase en su isolate y ejecuta `LocalChecks`. Los recordatorios se programan con `zonedSchedule` al abrir la app a partir de `plannedReminders` (dominio puro).

**Tech Stack:** firebase_messaging 16, flutter_local_notifications 22, workmanager 0.10, timezone, flutter_timezone 5, shared_preferences.

**Spec:** sección 6 y parte de 7. Depende del PR 3 (`feature/reportes-mvp`).

## Global Constraints

- Tuteo, "jornada". Color de notificaciones `#D4AF37`.
- Ids de notificación: actualización 4242; jugadores pendientes 4300; reportes por confirmar 4400 + hash(matchId) % 100; recordatorios 5000..5099 (dos por jornada: 09:00 y 22:00).
- Canales: `elfurbo_default` "El Furbo" (push de Functions), `elfurbo_updates` "Actualizaciones", `elfurbo_reminders` "Recordatorios".

---

### Task 1: Dominio puro: payload y recordatorios

**Files:** Create `lib/models/notification_payload.dart`, `lib/domain/reminders.dart`. Test `test/notifications_test.dart`.

**Interfaces:**
- `enum NotificationKind { update, matchDay, postMatch, report, reportStatus, pendingUser, unknown }`
- `class NotificationPayload { kind, matchId?, tag?; String encode(); static NotificationPayload decode(String?); factory fromFcmData(Map<String, dynamic>) }` — `type` en JSON usa los mismos nombres que las Functions: `update | match_day | post_match | report | report_status | pending_user`.
- `class PlannedReminder { int id; DateTime at; String title; String body; String matchId; }`
- `List<PlannedReminder> plannedReminders(List<MatchDay> matches, Map<String, AttendanceStatus?> myIntention, DateTime now, {int horizonDays = 14})`: para cada jornada no cancelada con `date` entre `now` y `now + horizon`, salvo que mi intención sea `no`: recordatorio a las 09:00 del día (si es futuro) "¡Hoy se juega!" / "Jornada a las HH:mm[ en lugar]. Marca si vas." y a las 22:00 del día (si es futuro y ≥ `end`) "¿Cuántos metiste hoy?" / "Carga tus goles y asistencias, y vota al MVP." Ids: `5000 + 2*i` y `5001 + 2*i` con i el índice de la jornada ordenada por fecha; máximo 50 jornadas.

- [ ] Tests: encode/decode ida y vuelta; `fromFcmData` mapea `type`; `plannedReminders` omite canceladas, intención `no`, fechas pasadas y fuera de horizonte; ids únicos.
- [ ] Implementar. Verde. Commit.

### Task 2: `LocalNotifications`

**Files:** Create `lib/services/local_notifications.dart`; Modify `lib/services/update_worker.dart` (quita `UpdateNotifications`, usa el nuevo servicio), `android/app/src/main/AndroidManifest.xml`.

**Interfaces:**
- `LocalNotifications.ensureInitialized({void Function(NotificationPayload)? onTap})`: crea canales, inicializa plugin, zona horaria (`tz`).
- `showUpdateAvailable(AppRelease)`, `showPendingUsers(int count)`, `showReportsToConfirm(String matchId, int count)`, `scheduleReminders(List<PlannedReminder>)` (cancela 5000..5099 primero), `cancelReminders()`, `cancelUpdate()`.
- `Future<NotificationPayload?> consumeLaunchPayload()`.
- Manifest: permiso `RECEIVE_BOOT_COMPLETED`, receivers `ScheduledNotificationReceiver` y `ScheduledNotificationBootReceiver`.

- [ ] Implementar. `flutter analyze`. Commit.

### Task 3: Router y shell

**Files:** Modify `lib/core/app_messenger.dart` (`rootNavigatorKey`, `requestedHomeTab` ValueNotifier<int?>), Create `lib/services/notification_router.dart`, Modify `lib/app.dart`, `lib/ui/shell/home_shell.dart`.

**Interfaces:** `NotificationRouter.handle(NotificationPayload p)`: `matchId` → `MatchDetailScreen.open(rootContext, matchId)`; `pendingUser` → `requestedHomeTab.value = HomeShell.adminTab`; `update` → `UpdateFlow.check(force: true)` (el chequeo existente en `_ActiveSession`). `HomeShell` escucha `requestedHomeTab` y cambia de pestaña si el admin está logueado.

- [ ] Implementar. Commit.

### Task 4: Tokens y push

**Files:** Modify `lib/services/push_service.dart`, `lib/data/firestore_repo.dart`, `firestore.rules`, `functions/index.js`, `lib/ui/profile/player_profile_screen.dart`, `lib/ui/auth/pending_screen.dart`; Create `lib/services/session.dart`.

**Interfaces:**
- Repo: `addFcmToken(uid, token)` (arrayUnion en `fcmTokens`), `removeFcmToken(uid, token)` (arrayRemove).
- `PushService.register(uid)`: token → `addFcmToken`; `onTokenRefresh` → `addFcmToken`; `getInitialMessage` + `onMessageOpenedApp` → `NotificationRouter.handle(NotificationPayload.fromFcmData)`.
- `PushService.unregister()`: `removeFcmToken(uid, token)` + `deleteToken()`.
- `signOutCompletely(ref)` en `session.dart`: `unregister`, `LocalNotifications.cancelReminders()`, `AuthService.signOut()`. Lo usan perfil y pantalla de espera.
- Reglas: `hasOnly([..., 'fcmToken', 'fcmTokens', 'updatedAt'])`.
- Functions `sendToUsers`: tokens = `fcmTokens` ∪ `fcmToken`; limpieza con `arrayRemove` (y `delete` del campo viejo). `matchDayReminder` excluye a quienes marcaron `no`. Locale `es`.

- [ ] Implementar. Desplegar reglas. Commit.

### Task 5: Chequeos locales y recordatorios

**Files:** Create `lib/services/local_checks.dart`; Modify `lib/services/update_worker.dart`, `lib/app.dart`.

**Interfaces:**
- `LocalChecks.run()` (en el worker): `Firebase.initializeApp()`; si no hay usuario, salir. Lee `users/{uid}`; si admin: `count` de `users where status == pending` y, si es mayor que el último notificado (prefs `checks.pendingUsers`), `showPendingUsers`. Para jornadas de los últimos 3 días (`matches where date >= now-3d && date <= now`) donde `attendance/{matchId_uid}.played == true`: cuenta reportes de otros con `adminStatus == null` y `confirmations.size < 2` que no me incluyan; si mayor al último notificado (`checks.reports.<matchId>`), `showReportsToConfirm`.
- `_ActiveSession`: tras el chequeo de actualización, `LocalNotifications.scheduleReminders(plannedReminders(...))` con las jornadas y mi intención actuales; se vuelve a programar cuando cambian las jornadas (listener del provider).

- [ ] Implementar. Commit.

### Task 6: Verificación

- [ ] `flutter analyze`, `flutter test`, build e instalación. Probar: tocar una notificación local abre la jornada; cerrar sesión borra el token (ver doc en Firestore); recordatorio programado aparece en ajustes de notificaciones.
- [ ] README: sección de notificaciones sin Blaze. Commit, PR (base `feature/reportes-mvp`).
