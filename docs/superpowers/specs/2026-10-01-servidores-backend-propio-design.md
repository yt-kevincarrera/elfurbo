# El Furbo 1.0: servidores, backend propio y modo sin conexión completo

Fecha: 2026-10-01. Estado: borrador para revisión del dueño del proyecto.

## Contexto y objetivo

Hoy El Furbo es una app para un solo grupo, montada sobre Firebase (Google
Sign-In, Firestore, Cloud Functions). La mayoría de los usuarios están en
Cuba, donde Google bloquea Firebase y Google Sign-In: sin VPN no se puede
entrar ni sincronizar.

La versión 1.0 tiene dos objetivos:

1. **Funcionar en Cuba sin VPN y sin coste.** Backend propio en Cloudflare
   Workers + D1 (plan gratuito). Validado el 2026-10-01: un Worker de prueba
   respondió y escribió en D1 desde ETECSA (país `CU`, AS27725, nodo MIA)
   sin VPN.
2. **Pasar de un grupo a muchos "servidores"** aislados entre sí, cada uno con
   su dueño, admins, jugadores, temporadas, jornadas y estadísticas. El dueño
   del proyecto es el superadmin.

Este documento es el **subproyecto 1** de una serie:

| # | Subproyecto | Estado |
|---|-------------|--------|
| 0 | Clave de firma de release del APK | Va dentro del corte a 1.0 (ver §11) |
| 1 | **Base nueva: backend, cuentas, servidores, sync offline, pachanga actual portada** | Este documento |
| 2 | Competición formal: equipos fijos, partidos con marcador y eventos, ligas | Pendiente |
| 3 | Torneos: eliminatorias, grupos, cuadro | Pendiente |
| 4 | Premios y votaciones | Pendiente |
| 5 | Gestión: pagos de cancha, sanciones, web para admins | Pendiente |

### Decisiones tomadas con el dueño

- Backend: Cloudflare Workers + D1, gratis. Sin Google salvo FCM para push.
- Crear servidores: cualquiera lo **solicita**, el superadmin lo **aprueba**.
- Datos actuales: **se empieza de cero**. Los datos de Firestore se quedan
  intactos en el proyecto de Firebase; la 1.0 no los lee.
- Login: usuario + contraseña. Recuperación con **código de un solo uso**
  generado por un admin del servidor o por el superadmin. Sin correo.
- **Todo funciona sin conexión**, incluido crear jornadas. Solo necesita red lo
  que por naturaleza depende del servidor (registro, login, unirse con
  invitación, recuperar contraseña, solicitar servidor, crear invitaciones).
- La jornada es la unidad. Equipos y partidos dentro de la jornada son
  opcionales: lo normal es crear la jornada y que cada uno cargue lo suyo.
- Quién crea jornadas: configurable por servidor; por defecto, cualquier
  miembro.
- Jugadores sin cuenta: los crea un admin o anotador; se pueden **reclamar**
  después con un código y conservan su historial.
- Validación de estadísticas: configurable por servidor, "con confirmación"
  (por defecto, como hoy) o "confianza". Lo que carga un admin o anotador
  cuenta al momento.
- Notificaciones push: FCM llega en Cuba sin VPN; se mantiene, enviado desde
  el Worker.
- Sincronización: cola de acciones + sincronización por lotes (no tiempo real).

### Supuestos (corregibles)

- Solo Android. APK repartido por WhatsApp/Telegram y actualizaciones dentro
  de la app.
- Escala: decenas de servidores, cientos de usuarios.
- Una persona puede estar en varios servidores y cambiar entre ellos.
- Servidores privados: se entra solo por invitación. Sin directorio público.
- Texto visible: "servidor". En código y base de datos se llama `club` para no
  confundirlo con el servidor backend.

## 1. Arquitectura

```
elfurbo/
├── lib/               app Flutter
├── backend/           Cloudflare Worker (TypeScript)
│   ├── src/
│   │   ├── index.ts         router (Hono)
│   │   ├── auth/            registro, login, sesiones, recuperación
│   │   ├── clubs/           solicitudes, invitaciones, miembros
│   │   ├── sync/            push (comandos) y pull (cambios)
│   │   ├── commands/        un archivo por familia de comandos
│   │   ├── rules/           reglas de negocio puras (sin I/O)
│   │   ├── authz.ts         permisos por rol, único punto de control
│   │   ├── push/            FCM HTTP v1
│   │   ├── superadmin/      panel del superadmin
│   │   └── cron.ts          recordatorios programados
│   ├── migrations/    esquema D1 versionado (wrangler d1 migrations)
│   └── test/          vitest + @cloudflare/vitest-pool-workers (D1 local real)
└── shared-fixtures/   casos de reglas en JSON que prueban Dart y TypeScript
```

- **Un Worker `furbo-api`** en `workers.dev` y **una base D1**. Dos entornos:
  `staging` y `production`, cada uno con su Worker y su D1 (el plan gratuito
  permite varios).
- **La app lee solo de su base local** (SQLite con `drift`). La red nunca
  bloquea la interfaz.
- **Reglas en los dos lados.** Dart para la respuesta inmediata sin conexión y
  TypeScript como autoridad. `shared-fixtures/` contiene casos
  `{estado, comando, resultado esperado}` que ambos lados ejecutan en sus
  tests, para que no diverjan.
- **Firebase queda solo para FCM** (`firebase_core` + `firebase_messaging`).
  Se eliminan `firebase_auth`, `cloud_firestore`, `google_sign_in`,
  `functions/`, `firestore.rules` y `firestore-tests/`.
- Se reutilizan del código actual: `StatsEngine`, `TeamBalancer`, logros,
  `matchday_rules`, Riverpod, la tarjeta para WhatsApp y la mayoría de las
  pantallas (cambian su fuente de datos).

### Presupuesto del plan gratuito

| Recurso | Límite gratis | Uso estimado |
|---------|---------------|--------------|
| Peticiones Worker | 100k/día | ~20 por usuario activo/día → margen para ~5.000 activos |
| CPU por petición | 10 ms | Hash de contraseña con PBKDF2 nativo (WebCrypto); el resto es JSON y SQL |
| D1 lecturas | 5M filas/día | Pull incremental; snapshots solo al unirse |
| D1 escrituras | 100k filas/día | Cada comando escribe 2–4 filas |
| D1 almacenamiento | 5 GB | Muy por encima de lo necesario |
| Cron triggers | 5 | Se usa 1 (cada hora) |

Si un día se superan, el plan de pago de Workers cuesta 5 USD/mes; el diseño
no cambia.

## 2. Modelo de datos (D1)

Todas las tablas de datos de un servidor llevan `club_id` y **toda consulta
filtra por `club_id`**. Los identificadores son UUID v7 generados en el
cliente (ordenables por tiempo), salvo los de cuentas y sesiones, que genera el
servidor. Las fechas se guardan como ISO 8601 UTC; cada servidor tiene su zona
horaria (por defecto `America/Havana`).

### Global

**`users`**: `id`, `username` (único, minúsculas, `[a-z0-9_.]{3,20}`),
`display_name`, `password_hash` (PBKDF2-SHA256, 100.000 iteraciones, sal de
16 bytes), `is_superadmin` (bool), `status` (`active`/`suspended`),
`created_at`, `updated_at`.

**`sessions`**: `id`, `user_id`, `token_hash` (SHA-256 del token opaco),
`device_label`, `created_at`, `last_seen_at`, `expires_at` (180 días,
deslizante).

**`devices`**: `user_id`, `fcm_token` (único), `last_seen_at`.

**`login_attempts`**: `key` (usuario o IP), `window_start`, `count`.

**`recovery_codes`**: `id`, `user_id`, `code_hash`, `created_by`,
`expires_at` (24 h), `used_at`.

### Servidores y miembros

**`clubs`**: `id`, `name`, `description`, `status`
(`pending`/`active`/`rejected`/`suspended`), `owner_user_id`,
`request_note`, `reviewed_by`, `reviewed_at`, `settings` (JSON, ver abajo),
`created_at`, `updated_at`.

`settings`:

| clave | valores | por defecto |
|-------|---------|-------------|
| `matchdayCreators` | `members` / `staff` | `members` |
| `reportValidation` | `confirm` / `trust` | `confirm` |
| `confirmationsNeeded` | 1–5 | 2 |
| `closeAfterHours` | 24–168 | 72 |
| `timezone` | IANA | `America/Havana` |

**`members`**: la identidad que acumula estadísticas dentro de un servidor.
`id`, `club_id`, `user_id` (null si es jugador sin cuenta), `role`
(`owner`/`admin`/`scorer`/`player`/`guest`), `status`
(`active`/`left`/`banned`), `display_name`, `nickname`, `created_by`,
`claimed_at`, `created_at`, `updated_at`. Único por `(club_id, user_id)`
cuando `user_id` no es null.

Todas las estadísticas apuntan a `member_id`, nunca a `user_id`. Así un
jugador sin cuenta y uno con cuenta se tratan igual, y reclamar un perfil es
solo rellenar `user_id`.

**`invites`**: `code` (8 caracteres de un alfabeto sin ambiguos, p. ej. sin
`0/O/1/I`), `club_id`, `role` (`player`/`scorer`/`admin`),
`target_member_id` (jugador sin cuenta a reclamar, opcional), `max_uses`
(1–100; 1 si es para reclamar), `uses`, `expires_at` (por defecto 7 días,
máximo 30), `created_by`, `revoked_at`.

### Datos de la pachanga (por servidor)

**`seasons`**: `id`, `club_id`, `name`, `start_date`, `is_active`,
`is_closed`, `updated_at`.

**`matchdays`**: `id`, `club_id`, `season_id`, `starts_at`,
`duration_minutes` (30–600, por defecto 120), `place`, `notes`, `status`
(`scheduled`/`cancelled`/`closed`/`reopened`), `teams` (JSON opcional:
`{a: [memberId], b: [memberId]}`), `created_by`, `updated_at`,
`deleted_at`.

**`attendance`**: `matchday_id`, `member_id`, `club_id`, `intent`
(`yes`/`no`/`maybe`/null), `played` (bool/null), `played_set_by`,
`updated_at`. Clave `(matchday_id, member_id)`.

**`reports`**: `matchday_id`, `member_id`, `club_id`, `goals`, `assists`
(0–30), `note`, `loaded_by` (member que lo cargó; si es staff, cuenta al
momento), `decision` (`confirmed`/`rejected`/null, decisión de staff),
`corrected_by`, `updated_at`. Clave `(matchday_id, member_id)`.

**`report_confirmations`**: `matchday_id`, `member_id` (autor del reporte),
`confirmer_id`, `club_id`, `created_at`. Tabla aparte (y no una lista dentro
del reporte) para que confirmar sin conexión nunca choque con otra
confirmación.

**`mvp_votes`**: `matchday_id`, `voter_id`, `club_id`, `voted_for`,
`updated_at`.

Un reporte **cuenta** si:
- `decision = confirmed`, o
- `loaded_by` es staff (owner/admin/scorer) y `decision` no es `rejected`, o
- el servidor está en `trust` y `decision` no es `rejected`, o
- el servidor está en `confirm`, `decision` es null y tiene al menos
  `confirmationsNeeded` confirmaciones de miembros presentes.

### Infraestructura de sincronización y auditoría

**`changes`**: `id` (autoincremental), `club_id`, `entity`, `entity_key`,
`op` (`upsert`/`delete`), `at`. Cada escritura de un comando añade aquí una
fila por entidad tocada. Es lo que lee el pull.

**`applied_commands`**: `id` (UUID del comando), `user_id`, `result` (JSON),
`at`. Hace los comandos idempotentes. Se purga a los 30 días.

**`audit_log`**: `id`, `club_id` (null si es global), `actor_user_id`,
`action`, `entity`, `entity_key`, `summary` (JSON corto con antes/después),
`at`. Registra decisiones sobre reportes, correcciones, cambios de rol,
expulsiones, borrados, uniones de jornadas, ajustes del servidor y todas las
acciones del superadmin.

## 3. Cuentas y sesiones

Endpoints (todos necesitan conexión):

| Endpoint | Qué hace |
|----------|----------|
| `POST /auth/register` | `{username, password, displayName}` → sesión. Contraseña mínima de 8 caracteres. |
| `POST /auth/login` | `{username, password, deviceLabel}` → `{token, user}` |
| `POST /auth/logout` | Revoca la sesión actual y desvincula el token FCM |
| `POST /auth/recover` | `{username, code, newPassword}` → nueva sesión; revoca todas las anteriores |
| `POST /auth/password` | Cambiar contraseña conociendo la actual |
| `GET /me` | Usuario, servidores y roles |
| `DELETE /me` | Borra la cuenta (ver abajo) |

- **Token opaco** de 32 bytes aleatorios en `Authorization: Bearer`. En D1
  solo se guarda su SHA-256. Se puede revocar al instante y no hace falta
  gestionar JWT.
- **Límite de intentos**: 10 fallos en 15 minutos por usuario o por IP
  bloquean el login 15 minutos. La respuesta no revela si el usuario existe.
- **Códigos de recuperación**: los genera, con conexión,
  - el owner para cualquier miembro de su servidor,
  - un admin para miembros con rol `scorer` o `player`,
  - el superadmin para cualquiera.

  El código se muestra una sola vez para pasarlo por WhatsApp y queda en el
  registro de auditoría.
- **Borrar la cuenta**: elimina `users`, `sessions` y `devices`. Sus
  `members` pasan a `user_id = null`, `role = guest`, `display_name =
  "Jugador eliminado"`. Las estadísticas de los servidores se conservan.
  Un owner no puede borrar su cuenta sin transferir antes sus servidores.
- **Superadmin**: se marca `is_superadmin = 1` con un comando
  `wrangler d1 execute` documentado en el README. No hay forma de
  convertirse en superadmin desde la API.

## 4. Servidores, roles e invitaciones

### Ciclo de vida de un servidor

1. Un usuario solicita un servidor (`POST /clubs`, con conexión) con nombre,
   descripción y nota. Queda `pending`. Máximo 3 servidores `pending` o
   `active` como owner por usuario.
2. El superadmin recibe un push y lo aprueba o rechaza desde su panel. Si se
   aprueba pasa a `active`, se crea el `member` owner y se crea una temporada
   inicial con el año en curso. El solicitante recibe un push.
3. Si el superadmin lo suspende (`suspended`), el servidor queda en solo
   lectura para sus miembros, con un aviso. Se puede reactivar.

### Permisos por rol

| Acción | owner | admin | scorer | player |
|--------|:-----:|:-----:|:------:|:------:|
| Ajustes del servidor, transferir propiedad | ✓ | | | |
| Nombrar o quitar admins | ✓ | | | |
| Nombrar scorer/player, expulsar miembros | ✓ | ✓ | | |
| Invitar como player o scorer | ✓ | ✓ | | |
| Invitar como admin | ✓ | | | |
| Códigos de recuperación | ✓ | ✓ (solo para scorer/player) | | |
| Temporadas (crear, cerrar, activar, borrar) | ✓ | ✓ | | |
| Crear jornadas | ✓ | ✓ | ✓ | si `matchdayCreators = members` |
| Editar jornadas | ✓ | ✓ | ✓ | solo las que creó |
| Cancelar, cerrar, reabrir y borrar jornadas; unir duplicadas | ✓ | ✓ | ✓ | solo las que creó y sin reportes de otros |
| Pasar lista, cargar estadísticas de cualquiera | ✓ | ✓ | ✓ | |
| Crear jugadores sin cuenta | ✓ | ✓ | ✓ | |
| Decidir sobre reportes (confirmar, rechazar, corregir) | ✓ | ✓ | | |
| Asistencia propia, reporte propio, confirmar otros, votar MVP | ✓ | ✓ | ✓ | ✓ |
| Guardar equipos | ✓ | ✓ | ✓ | |

Todo pasa por una única función `authorize(user, clubId, action, target)` en
`backend/src/authz.ts`. Un usuario que no es miembro activo de un servidor
recibe `404` en cualquier recurso de ese servidor (no `403`, para no confirmar
que existe).

El superadmin puede **leer** cualquier servidor para dar soporte, y cualquier
**escritura** suya queda en la auditoría. No participa en las estadísticas de
un servidor salvo que sea miembro.

### Invitaciones

- Las crean owner y admin con conexión: rol, usos (1–100) y caducidad
  (1–30 días). Se pueden revocar.
- Se comparten como enlace `https://furbo-api.<subdominio>.workers.dev/i/<CODE>`. Esa URL muestra una
  página ligera con el nombre del servidor, el código y cómo instalar la app.
  Además abre la app directamente (`elfurbo://invite/<CODE>`) si ya está
  instalada. Dentro de la app también se puede escribir el código a mano.
- Aceptar (`POST /invites/<CODE>/accept`, con conexión) crea el `member`, o
  reclama el jugador sin cuenta de `target_member_id`: rellena `user_id` y
  pasa a `role = player`. Si el usuario ya es miembro de ese servidor, no se
  puede reclamar otro perfil (error claro: "ya eres miembro").

### Panel del superadmin (dentro de la app)

- Solicitudes pendientes: aprobar o rechazar con motivo.
- Lista de servidores: buscar, ver detalle, suspender o reactivar,
  transferir owner.
- Usuarios: buscar por nombre de usuario, suspender, generar código de
  recuperación.
- Métricas: usuarios y servidores activos (7 y 30 días), comandos por día y
  uso estimado frente a los límites del plan gratuito.

## 5. Sincronización

### Base local en la app

- **Tablas espejo** con el último estado conocido del servidor, por servidor.
- **Cola** (`outbox`) de comandos pendientes:
  `{id, clubId, type, payload, clientAt, attempts, lastError}`.
- **Vista**: la interfaz lee "estado del servidor + comandos pendientes
  aplicados encima". Cada tipo de comando tiene un reductor en Dart que lo
  aplica sobre las tablas locales. Tras cada pull se recalcula la vista
  volviendo a aplicar los pendientes. Así el cambio local se ve al instante y
  nunca se pierde por un pull.

### Comandos

Un comando es `{id: uuidv7, clubId, type, payload, clientAt}`. Tipos de la
1.0:

- `season.create|update|activate|setClosed|delete`
- `matchday.create|update|setStatus|delete|merge`
- `attendance.setIntent|setPlayed|rollCall`
- `report.upsert|delete|confirm|unconfirm|decide|correct|loadFor`
- `vote.cast|clear`
- `teams.save`
- `member.createGuest|update|setRole|ban|unban|leave`
- `club.updateSettings`

Los que necesitan conexión (invitar, aceptar invitación, códigos de
recuperación, solicitar servidor, superadmin) son endpoints normales, no
comandos.

### Push

`POST /sync/push` con `{commands: [...]}`, máximo 200 comandos y 256 KB.

- Se procesan en orden. Cada uno se valida (permisos y reglas) y se aplica en
  una transacción de D1 (`batch`) junto con sus filas de `changes`,
  `audit_log` (si toca) y `applied_commands`.
- Respuesta por comando: `applied`, `duplicate` (ya aplicado antes: devuelve
  el resultado guardado) o `rejected` con `code` y un `message` en español.
- Un comando rechazado no bloquea los siguientes.

### Pull

`POST /sync/pull` con `{cursors: {clubId: changeId}}`.

- Devuelve, por servidor, las filas actuales de las entidades cambiadas desde
  el cursor (agrupadas y sin repetir), las bajas como tombstones, el nuevo
  cursor y `hasMore`. Máximo 500 cambios por respuesta.
- Cursor `0`, o un cursor más viejo que la purga de `changes` (90 días):
  **snapshot** completo de ese servidor y el cursor actual. Los cursores son
  ids globales de `changes`: sin cambios nuevos en un servidor, su cursor
  avanza hasta el último id que existe, así uno tranquilo nunca cae por
  debajo de la purga. La purga diaria (08:00 UTC, en el cron de cada hora)
  guarda en `kv` hasta qué id borró; un pull que coincide con ella la vuelve
  a leer al final y repite como foto completa lo que pudo perderse. La misma
  purga borra `applied_commands` de más de 30 días, sesiones caducadas hace
  más de 7, intentos de login viejos y códigos de recuperación caducados.
- También informa de los servidores a los que el usuario ya no pertenece, para
  que la app borre sus datos locales.

### Cuándo se sincroniza

- Al abrir la app.
- 3 segundos después de cada acción local (agrupando varias).
- Cada 2 minutos con la app en primer plano.
- Al recibir un push (todos los push llevan `sync: 1`).
- En segundo plano con WorkManager (el intervalo mínimo de Android, ~15 min,
  cuando el sistema lo permite) y, si al salir de la app quedan cambios por
  enviar, en cuanto haya conexión. La app abierta y el sync de segundo plano
  pueden coincidir (isolates distintos, mismos archivos): la cola y los
  rechazados son un archivo por cambio, nunca un archivo que se reescribe, así
  que lo peor es enviar un cambio dos veces (el servidor lo ve duplicado).
- Tras un fallo con cambios por enviar, reintentos a 5 s, 10 s, 20 s… hasta
  5 min.

Las respuestas viajan comprimidas (Cloudflare comprime JSON).

### Conflictos

- **Gana el último en llegar al servidor.** No se usa la hora del teléfono
  para ordenar, porque los relojes no son fiables.
- Las confirmaciones y los votos son por persona y no chocan.
- **Plazo de cierre de jornada** (`closeAfterHours`): se evalúa con
  `clientAt` si es anterior a la hora del servidor y de hace menos de 7 días.
  Si no, con la hora del servidor. Así no se rechaza un reporte hecho a
  tiempo sin señal y subido después. Un cierre **manual** gana siempre: si la
  jornada ya estaba cerrada a mano cuando llega el comando, se rechaza.
- **Jornadas duplicadas**: al crear una jornada, y al recibir jornadas en un
  pull, la app detecta otras del mismo servidor el mismo día local. Si las
  hay, muestra "Parece que hay dos jornadas del sábado 4. ¿Unirlas?". El
  comando `matchday.merge {from, into}` mueve la asistencia, los reportes,
  las confirmaciones y los votos de `from` a `into`. Si un mismo miembro
  tiene datos en ambas, se queda el más reciente por `updated_at`. Después
  se borra `from` y queda en la auditoría.

### Errores visibles

- **Indicador de sincronización** en la barra superior: "Todo al día",
  "3 cambios por enviar", o "Sin conexión · último sync 14:32".
- **"Cambios no aplicados"**: lista de comandos rechazados con su motivo
  (p. ej. "La jornada ya estaba cerrada"). El usuario los descarta, y los que
  se pueden corregir (un reporte) se abren para editarlos.
- **Reintentos** con espera creciente (5 s → 5 min). Un `401` lleva al
  login sin perder la cola. Al volver a entrar con el mismo usuario se envía.

## 6. Pachanga portada al modelo nuevo

El comportamiento de la spec de 2026-09-14 se mantiene, adaptado a
servidores y miembros:

- Jornadas con duración, estados, cierre automático (ahora configurable con
  `closeAfterHours`), repetición semanal (hasta 26, un comando
  `matchday.create` por fecha) y temporadas con cierre.
- Asistencia (intención antes, "Jugué / No fui" después), pasar lista.
- Reportes con confirmación de compañeros presentes, decisión y corrección
  del staff, rechazo definitivo para el autor, aviso al editar un reporte ya
  confirmado. Nuevo: `report.loadFor` para que el staff cargue estadísticas
  de cualquiera, incluidos los jugadores sin cuenta.
- MVP con el mismo desempate. Votan los presentes con cuenta; se puede votar
  a un jugador sin cuenta presente.
- Equipos equilibrados con `TeamBalancer`; guardarlos es opcional.
- Tabla, perfil, evolución, logros y tarjeta de WhatsApp, por servidor.
- `StatsEngine` pasa a trabajar con `memberId` y con la regla de "cuenta" de
  §2.

### Pantallas nuevas o cambiadas

- **Bienvenida**: "Entrar", "Crear cuenta", "Tengo un código de
  invitación".
- **Selector de servidor** (arriba en el shell) y pantalla "Mis
  servidores" con "Unirme con código" y "Solicitar un servidor".
- **Sin servidores**: explica cómo conseguir una invitación o solicitar uno.
- **Admin del servidor**: miembros (roles, expulsar, códigos de
  recuperación), jugadores sin cuenta (crear, invitar a reclamar),
  invitaciones (crear, compartir, revocar), temporadas, ajustes y auditoría.
- **Superadmin**: §4. Solo visible si `is_superadmin`.
- **Indicador de sync** y **"Cambios no aplicados"**: §5.

## 7. Notificaciones

Sin push. FCM no sirve desde Cuba: el teléfono tiene que pedir su token a las
API de Firebase (`firebaseinstallations`, `fcmregistrations`), que rechazan
las peticiones sin VPN, igual que Firestore y Auth. Los avisos los calcula el
propio teléfono con lo que trae el sync (`lib/cloud/sync/alerts.dart`):

- El sync de segundo plano (WorkManager, ~15 min) trae los datos; después pone
  al día `/me` y, si soy superadmin, las solicitudes pendientes.
- Cada aviso tiene una clave estable. Se guarda cuáles ya se mostraron
  (`alerts.json` de la cuenta). La primera pasada solo marca todo como visto.
- Con la app a la vista, lo nuevo se marca como visto sin avisar. Abierta pero
  en segundo plano, avisa ella.
- Eventos:
  - Jornada nueva de otro, por jugar, en la que no dije nada.
  - Reporte de otro que puedo confirmar (jugué, sin decidir, le faltan
    confirmaciones, jornada sin cerrar). Si lo editan, la clave cambia y se
    vuelve a avisar.
  - Mi reporte rechazado.
  - Mi servidor aprobado; mi solicitud rechazada (con la nota).
  - Superadmin: solicitud de servidor nueva.
- Varios del mismo tipo y servidor van en uno ("3 jornadas nuevas"). Uno nuevo
  del mismo tipo reemplaza al anterior en la barra.
- "¡Hoy se juega!" (09:00) y "¿Cuántos metiste hoy?" (22:00) siguen siendo
  recordatorios programados en el teléfono para el servidor elegido.
- Tocar un aviso cambia a su servidor y abre la jornada (o el panel de
  superadmin).
- Contra: no es instantáneo (de 15 min a más con el teléfono en reposo), y en
  teléfonos que matan las apps en segundo plano puede no llegar hasta abrir la
  app.

## 8. Actualizaciones de la app sin GitHub

GitHub no abre desde Cuba. El Worker hace de intermediario:

- `GET /app/latest` → `{minSupportedBuild, release}`. `release` es
  `{tag, version, build, title, notes, publishedAt, assets: [{abi, name, size,
  url}]}` o null. Se lee de la última release de GitHub y se guarda 1 hora en
  la tabla `kv`. Si GitHub falla (o el límite de 60 consultas por hora de la
  IP de Cloudflare), se sirve la última que se vio. Un secreto opcional
  `GITHUB_TOKEN` sube ese límite.
- `GET /app/apk/<tag>/<abi>` → transmite el APK de esa release. El Worker lo
  pide a GitHub desde Cloudflare, así que el teléfono nunca toca GitHub. No se
  almacena nada en Cloudflare. Respeta `Range`: una descarga cortada sigue
  donde se quedó (el `.part` en el teléfono lleva la versión en el nombre).
- `minSupportedBuild` (variable `MIN_SUPPORTED_BUILD` del Worker) permite
  forzar la actualización si un cambio del protocolo de sync lo exige. La app
  manda su build en `x-app-build` y `/sync/*` responde 426 `app_outdated` a
  las más viejas (y a las que no lo mandan).
- Cada APK lleva el sha256 que da GitHub; la app lo comprueba antes de darlo
  por descargado. La app muestra "Actualiza para seguir
  sincronizando" y sigue funcionando sin conexión.
- `release.sh` sigue publicando en GitHub Releases. No cambia nada para el
  dueño.

## 9. Seguridad

- Aislamiento: `authorize()` es el único punto de control y todas las
  consultas filtran por `club_id`. Hay tests específicos de intentos entre
  servidores (leer, escribir, invitar, pull de un servidor ajeno).
- Validación de toda entrada con `zod`. Comandos de tipo desconocido se
  rechazan.
- Contraseñas con PBKDF2; tokens, códigos de recuperación e invitaciones
  generados con `crypto.getRandomValues`. Los tokens y los códigos de
  recuperación se guardan hasheados.
- Límite de peticiones por sesión: 120 por minuto; 429 con reintento.
- Copias de seguridad: D1 Time Travel (recuperación a cualquier minuto de
  los últimos 7 días en el plan gratuito). Además, un export manual
  documentado en el README.

## 10. Pruebas y CI

- **Backend** (`vitest` sobre `workerd` con D1 local):
  - auth: registro, login, bloqueo por intentos, recuperación, borrado de
    cuenta;
  - permisos: matriz completa de §4 y aislamiento entre servidores;
  - sync: idempotencia, orden, rechazo parcial, pull incremental, snapshot,
    purga, servidores abandonados;
  - reglas: cierre con `clientAt`, cierre manual, regla de "cuenta",
    unión de jornadas.
- **Fixtures compartidos** (`shared-fixtures/*.json`): los ejecutan los
  tests de TypeScript y de Dart.
- **App**:
  - reductores de comandos sobre `drift` en memoria;
  - la cola y el recálculo de la vista tras un pull;
  - `StatsEngine` con miembros sin cuenta y con los dos modos de validación;
  - detección de jornadas duplicadas.
- **Integración**: un test de Dart que arranca `wrangler dev` y recorre
  registro → solicitud → aprobación → invitación → jornada sin conexión →
  sync → tabla.
- **CI** (`.github/workflows/ci.yml`): se añaden `npm test` y `tsc` del
  backend, y se quitan los tests de reglas de Firestore y el chequeo de
  Functions. Despliegue a `staging` automático en cada push a `main`. A
  `production`, a mano con `npm run deploy:prod` o al publicar una release.

## 11. Corte a 1.0 y clave de firma

- La 1.0 se publica con el mismo paquete `app.elfurbo`, pero **firmada con
  una clave de release nueva**. Hoy se firma con la clave debug de la PC.
  Como la 1.0 empieza de cero de todas formas, este es el momento de
  cambiar la clave: cada usuario desinstala la versión vieja una vez e
  instala la 1.0. A partir de ahí las actualizaciones vuelven a ser
  automáticas.
- La clave (`.jks`) y sus contraseñas se guardan fuera del repo, con copia de
  seguridad en un sitio seguro. `release.sh` y Gradle la leen desde
  `key.properties`, que está en `.gitignore`.
- El proyecto de Firebase y los datos de Firestore se conservan sin cambios.
  Solo se sigue usando FCM.
- El Worker de prueba `furbo-probe` y su D1 se borran al terminar el
  subproyecto.

## 12. Orden de entrega (PRs)

1. **Backend base**: proyecto `backend/`, migraciones, auth y sesiones,
   tests y despliegue a `staging`.
2. **Servidores**: solicitudes, aprobación del superadmin, miembros,
   jugadores sin cuenta, invitaciones, códigos de recuperación y auditoría.
3. **Sync en el backend**: push y pull, todos los comandos de §5 y
   `shared-fixtures`.
4. **App, base**: `drift`, cola, reductores, sincronizador, pantallas de
   bienvenida, cuenta, selector de servidor e indicador de sync.
5. **App, pachanga portada**: jornadas, asistencia, reportes, MVP, equipos,
   tabla y perfil sobre la base local. Admin del servidor y panel del
   superadmin.
6. **Notificaciones y actualizaciones**: FCM desde el Worker, cron, `/app/*`.
7. **Corte a 1.0**: clave de release, quitar Firebase Auth, Firestore y
   Functions, actualizar README, release 1.0.0 y borrar `furbo-probe`.

## Fuera de alcance

Equipos fijos, partidos con marcador, ligas, torneos, premios, pagos,
sanciones, web, iOS, correo electrónico, tiempo real, directorio público de
servidores, migración de los datos de Firestore.
