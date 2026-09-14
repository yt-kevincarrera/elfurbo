# PR 5: Cuenta y pulido

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el jugador pueda eliminar su cuenta, que el banner de sin conexión no parpadee al abrir y que la espera del perfil ofrezca reintentar.

**Architecture:** `AuthService.deleteAccount()` borra la cuenta de Firebase Auth reautenticando con Google si hace falta; `deleteAccountCompletely(ref)` en `session.dart` orquesta baja de token, recordatorios, borrado del perfil y de la cuenta. `SyncBanner` espera un período de gracia o el primer snapshot del servidor. `AuthGate` muestra "Reintentar" si el perfil tarda.

**Spec:** sección 7. Depende del PR 4 (`feature/notificaciones`).

---

### Task 1: Eliminar cuenta
- Repo: `deleteUserDoc(uid)`. Reglas: `allow delete` propio en `users`. Desplegar.
- `AuthService.deleteAccount()`: `user.delete()`; si `requires-recent-login`, `GoogleSignIn.authenticate()` → `reauthenticateWithCredential` → reintentar.
- `session.dart`: `deleteAccountCompletely(ref)`: `unregister`, `cancelReminders`, `deleteUserDoc`, `deleteAccount`.
- Perfil: menú "Eliminar mi cuenta" con diálogo de confirmación (explica que el historial queda como "Jugador").

### Task 2: Banner sin parpadeo
- `SyncBanner` pasa a `ConsumerStatefulWidget`: no muestra "Sin conexión" hasta que pasen 3 s o llegue un snapshot del servidor.

### Task 3: Reintento del perfil
- `AuthGate`: la espera "Preparando tu perfil…" muestra "Reintentar" a los 8 s, que vuelve a llamar `ensureUserDoc`.

### Task 4: Verificación
- analyze, test, build, README, PR (base `feature/notificaciones`).
