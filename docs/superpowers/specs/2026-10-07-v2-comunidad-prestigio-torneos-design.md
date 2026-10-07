# El Furbo 2.0: moverse entre servidores, prestigio, directorio y torneos

Fecha: 2026-10-07. Estado: aprobado por el dueño para ejecutarse de corrido
("elabora el plan que recoja todo esto y métele sin parar"). Las decisiones que
no tomó él las tomé yo y están marcadas como **(decidido)**; se pueden corregir
en cualquier PR.

## Contexto y objetivo

La 1.0 dejó la base: servidores aislados, sync sin conexión con cola de
comandos, backend propio en Cloudflare y avisos locales. La 2.0 junta lo que
el dueño pidió el 2026-10-07:

1. **Cambiar de servidor** sin perderse cuando uno está en varios.
2. **Servidores públicos** (en un directorio) y **privados** (solo por
   invitación), y **servidores oficiales**.
3. **Prestigio por servidor**: las estadísticas de alguien no se miran en
   bruto, sino junto con el nivel del servidor donde las hizo. Lo de un
   servidor oficial pesa como lo de uno de prestigio.
4. **Perfil global**: al mirar a un jugador se ve qué hizo en cada servidor.
5. **Torneos** completos: inscripción de equipos, reglas, liga, copa o grupos
   con eliminatorias, cuadro, resultados, tablas, sanciones y premios.
6. **Más ideas** de la lista que se le propuso: comprobar asistencia en el
   terreno, cupo y lista de espera, carta para compartir, resumen de temporada
   y récords.

Siguen valiendo todas las reglas de la 1.0
(`2026-10-01-servidores-backend-propio-design.md`):
- nada de Google;
- todo funciona sin conexión salvo lo que por naturaleza necesita al servidor;
- plan gratuito de Cloudflare;
- texto en tono cubano (`docs/tono.md`);
- "servidor" en pantalla y `club` en el código.

### Decisiones

- **Un torneo es un servidor de tipo `tournament`** **(decidido)**:
  - **Qué reutiliza:** roles, invitaciones, la cola de comandos, el pull, los
    avisos, la auditoría y el selector. La app lo sincroniza como cualquier
    otro servidor.
  - **Equipos de varios servidores:** caben sin romper el aislamiento, porque
    el torneo es su propio servidor.
  - **Quién lo crea:** el owner o un admin de un servidor activo (el
    "anfitrión"), sin pasar por el superadmin. Hay como mucho 3 torneos sin
    terminar por anfitrión.
- **Equipos de cualquier servidor** **(decidido)**:
  - Un torneo admite equipos con gente de distintos servidores.
  - Cada equipo puede decir a qué servidor representa ("Copa de servidores").
- **El backend también calcula las estadísticas** **(decidido)**:
  - Lo hace un puerto en TypeScript del `StatsEngine`, y los dos lados pasan
    los mismos casos de `shared-fixtures/`.
  - Guarda los totales por temporada y miembro.
  - Esos totales alimentan el perfil global, el prestigio, el directorio y las
    páginas web públicas.
  - El teléfono sigue calculando la tabla de cada servidor como hasta ahora.
- **Prestigio calculado, no puesto a mano:**
  - Solo "oficial" lo pone el superadmin.
  - El nivel de cada temporada se **congela al cerrarla**.
- **Privacidad de lo que sale en el perfil** **(decidido)**:
  - **Servidores públicos:** sus estadísticas salen con el nombre del servidor.
  - **Servidores privados:** salen como "Servidor privado", con su nivel. Si
    quien mira también es miembro de ese servidor, ve el nombre.
  - **El servidor** puede no compartirlas: ajuste `shareStats`.
  - **El jugador** puede ocultar lo de sus servidores privados:
    `showPrivateStats`.
- **Cómo se entra en un servidor público:** siempre con solicitud **(decidido)**.
  - El dueño puede elegir que sea abierto: entra quien lo pida.
  - Un privado no sale en el directorio y solo admite invitación, como hoy.
- **Comprobar asistencia con un código de 6 cifras** que muestra el staff
  **(decidido)**. Va sin cámara para no meter ML Kit de Google en el APK.
- **Sin push** (como la 1.0): los avisos nuevos salen del sync y de `/me`.
- **Fuera de la 2.0:**
  - pagos del terreno, "falta uno", retos entre servidores y ELO por
    resultados;
  - widget de Android, versión web o iPhone;
  - sistema suizo y doble eliminación.

  Quedan anotados al final.

## 1. Cambiar de servidor

Hoy:
- Se toca el nombre del servidor arriba y sale la hoja "Tus servidores".
- Tocar un aviso cambia al servidor del aviso.

La 2.0 mejora la hoja y añade una agenda común.

### La hoja "Tus servidores"

- Va en dos grupos, **Servidores** y **Torneos**, cada uno ordenado por
  actividad reciente.
- Cada fila lleva:
  - la ficha con las iniciales en el **color del servidor**;
  - el nombre;
  - el rol;
  - el nivel de prestigio (§4).
- Cada fila lleva además **un número con lo que tienes pendiente ahí**. Usa las
  mismas reglas que los avisos (`alerts.dart`), sobre la vista local de ese
  servidor:
  - jornadas por jugar en las que no dijiste nada;
  - reportes que puedes confirmar;
  - partidos de torneo que te toca anotar;
  - para admins, solicitudes de entrada.
- El que se está mirando sale marcado.
- Al final, "Buscar servidores" (abre el directorio, §6) y "Unirme con un
  código".

### Agenda

- Es la primera entrada de la hoja: "Agenda de todos".
- Junta las jornadas y los partidos de los próximos 14 días de **todos** mis
  servidores, ordenados por fecha. Cada uno lleva la ficha de su servidor.
- Las jornadas permiten responder *Voy / Quizás / No voy* ahí mismo (un
  comando a la cola del servidor que toca).
- Tocar una fila cambia a ese servidor y la abre.
- Funciona sin conexión: la vista local de cada servidor ya está en el
  teléfono.

### Color del servidor

- El dueño elige uno de 8 colores de tiza.
- Sale en:
  - la ficha;
  - la barra de arriba;
  - la agenda;
  - el directorio;
  - las páginas web.

## 2. Identidad y visibilidad del servidor

### Datos

Columnas nuevas en `clubs` (migración `0008`):

| columna | valores | por defecto |
|---------|---------|-------------|
| `kind` | `group` / `tournament` | `group` |
| `visibility` | `private` / `public` | `private` |
| `official` | 0 / 1 (solo el superadmin) | 0 |
| `province` | una de las provincias (abajo) o null | null |
| `city` | texto ≤ 40 o null | null |
| `color` | 0–7 (paleta de tiza) | 0 |
| `host_club_id` | servidor anfitrión de un torneo | null |
| `checkin_secret` | 32 bytes aleatorios en hex (§8.1), nunca viaja en el pull | null |

Provincias: Pinar del Río, Artemisa, La Habana, Mayabeque, Matanzas,
Cienfuegos, Villa Clara, Sancti Spíritus, Ciego de Ávila, Camagüey, Las Tunas,
Holguín, Granma, Santiago de Cuba, Guantánamo, Isla de la Juventud, Fuera de
Cuba. Se guardan con un código corto: `pri`, `art`, `hab`, `may`, `mat`, `cfg`,
`vcl`, `ssp`, `cav`, `cam`, `ltu`, `hol`, `gra`, `stg`, `gtm`, `ijv`, `ext`.

Ajustes nuevos en `settings`:

| clave | valores | por defecto |
|-------|---------|-------------|
| `joinPolicy` | `request` / `open` (solo cuenta si es público) | `request` |
| `shareStats` | bool | true |
| `maxPlayers` | 0 (sin límite) – 60: cupo por defecto de las jornadas nuevas (§8.2) | 0 |

### Comandos nuevos

Solo el owner:
- `club.updateProfile {name?, description?, province?, city?, color?}`:
  - el nombre tiene de 3 a 40 caracteres;
  - la descripción, hasta 300;
  - `province` va con su código.
- `club.setVisibility {visibility, joinPolicy?}`.

### Superadmin

- `POST /admin/clubs/:id/official {official, note}`: marca o desmarca un
  servidor (o un torneo) como oficial.
- `POST /admin/clubs/:id/delist {delisted, note}`: lo saca del directorio (lo
  pasa a privado y marca `clubs.delisted`) si su nombre o su descripción no son
  aptos. Mientras esté marcado, su dueño no lo puede volver a hacer público
  (`club_delisted`). Con `delisted: false` se permite otra vez.
- Las dos acciones quedan en la auditoría, y las dos escriben un cambio
  `club` para que el pull lo lleve.

### Pull

La entidad `club` lleva además:
- `kind`, `visibility`, `official`, `province`, `city`, `color` y
  `hostClubId`;
- `tier` y `tierScore` (§4).

## 3. Estadísticas en el backend

### Reglas compartidas

- `backend/src/rules/stats.ts` hace lo mismo que `lib/domain/stats_engine.dart`:
  - la regla de "cuenta" de un reporte;
  - quién jugó cada jornada;
  - goles y asistencias confirmados;
  - MVP con su desempate;
  - hat-tricks y pókers;
  - la mejor racha;
  - lo máximo en un día.
- En Dart, la regla de "cuenta", que hoy vive dentro de `reportsProvider`,
  pasa a una función pura en `lib/domain/report_rules.dart`.
- `shared-fixtures/stats.json` tiene casos con entradas en el formato del pull
  (ajustes, jornadas, asistencia, reportes, confirmaciones y votos) y los
  totales esperados por miembro. Lo ejecutan los tests de los dos lados.

### Tablas

`member_stats`: totales por miembro y período.
- **Período:** una temporada en los servidores; el torneo entero en los
  torneos.
- **Clave:** `(club_id, period_id, member_id)`.
- **Columnas de juego:** `played`, `goals`, `assists`, `mvps`, `hat_tricks`,
  `best_streak` y `best_day_goals`.
- **Columnas de reportes:** `reports`, `rejected` y `checkins`.
- **Columnas de torneo:** `yellows` y `reds`.
- **Además:** `flag` (rareza, §4) y `updated_at`.

`club_metrics`: una fila por servidor.
- **Control del cálculo:**
  - `computed_through`: hasta qué cambio se calculó.
  - `computed_at`.
- **Prestigio:** `tier`, `score` y `signals` (JSON con las señales de §4).
- **Para el directorio:**
  - `play_days`: los días de la semana en que se juega, de las jornadas de los
    últimos 60 días;
  - `active_players`;
  - `last_played_at`.

`period_tiers`: el nivel con que se jugó cada período.
- **Columnas:** `club_id`, `period_id`, `tier`, `score` y `frozen_at`.
- **Período abierto:** su nivel sigue al del servidor.
- **Al cerrarlo:**
  - una temporada se congela al cerrarse;
  - un torneo, al terminar.
- **Al reabrir:** se descongela.

### El cálculo

- Corre en el cron, que pasa de cada hora a **cada 10 minutos**. La purga sigue
  siendo una vez al día, a las 08:00 UTC.
- **Qué servidores recalcula en cada pasada:**
  - los que tienen cambios después de `computed_through` (consulta por el
    índice `changes_club`);
  - los que llevan más de 24 horas sin recalcular, porque las señales dependen
    de la fecha.
- **Cuántos:** hasta 6 servidores por pasada, con un tope de 600 consultas.
- **Cómo:** lee las tablas del servidor (7 consultas), calcula todo en memoria
  y reescribe sus filas en un `batch`.
- **Cambios para el pull:** si el nivel del servidor cambia, escribe un cambio
  `club` para que lo lleve el pull.
- **Retraso:** como mucho unos 10 minutos. Las pantallas dicen "se actualiza
  cada pocos minutos".

## 4. Prestigio

### Señales

Las calcula `club_metrics`. Las de actividad miran los últimos 90 días.

| señal | qué mide | peso |
|-------|----------|------|
| Antigüedad | días desde la primera jornada jugada, hasta 180 | 15 |
| Actividad | jornadas jugadas en 90 días, hasta 12 | 15 |
| Tamaño | jugadores por jornada en promedio, hasta 10 | 15 |
| Validación | ver abajo | 25 |
| Cuentas | % de los que jugaron que tienen cuenta | 15 |
| Red | % de los que jugaron (con cuenta) activos en otro servidor, hasta 30 % | 15 |

**Validación (25 puntos):**
- Modo `confirm`: 10.
- 2 o más confirmaciones: 5 más.
- % de reportes que cuentan cargados o decididos por el staff: hasta 5.
- % de presencias comprobadas con código (§8.1): hasta 5.

**Penalizaciones:**
- Más del 15 % de reportes rechazados: −10.
- Promedio de goles por jugador y jornada por encima de 3: −15.
- Por encima de 2: −5.

### Niveles

| nivel | regla |
|-------|-------|
| `official` | lo marcó el superadmin |
| `new` (Nuevo) | menos de 30 días o menos de 4 jornadas jugadas |
| `verified` (Verificado) | puntuación ≥ 70 y modo `confirm` |
| `established` (Establecido) | puntuación ≥ 40 |
| `casual` (Casual) | el resto |

El modo `trust` no pasa nunca de Establecido.

### Torneos

- `official` si el superadmin lo marcó.
- `verified` si tiene 4 equipos aprobados o más y su anfitrión es oficial o
  verificado.
- `established` si tiene 4 equipos aprobados o más.
- `casual` en el resto de casos.

En un torneo los resultados los pone el staff, así que la validación ya viene
dada.

### Rareza de un jugador

Un jugador queda marcado (`flag = 1`) si cumple las tres cosas:
- promedia más de 4 goles por jornada;
- lleva 3 jornadas o más;
- su promedio duplica el del servidor.

El perfil lo muestra discreto: "Promedio fuera de lo normal en este servidor".
No se borra nada.

### Índice Furbo

Un número para comparar a jugadores de distintos servidores:

```
peso: official 1.0 · verified 0.8 · established 0.5 · casual 0.25 · new 0.25
índice = Σ peso × (goles + 0.7·asistencias + 1.5·MVP) / Σ peso × jornadas
```

- Se calcula con el nivel congelado de cada período.
- Hacen falta 5 jornadas ponderadas o más; si no, sale "—".
- El perfil explica cómo se calcula.

### En la app

- Una ficha de nivel con colores de tiza: ⭐ Oficial en amarillo, ✓ Verificado
  en verde, Establecido en azul, Casual en gris y Nuevo en blanco.
- Sale en:
  - la barra del servidor;
  - la hoja de servidores;
  - el directorio;
  - el perfil global;
  - los ajustes. Ahí el dueño ve **qué le falta** para subir de nivel: las
    señales con su valor.

## 5. Perfil global

### `GET /players/:userId`

Cualquiera con sesión puede pedirlo. Devuelve:
- `user`: `id`, `username`, `displayName` y `since`.
- `memberships`: una por servidor donde tiene historial visible (con
  `played > 0`). Cada una lleva:
  - el servidor: `clubId`, `name` (null si es privado y quien mira no es
    miembro), `kind`, `official`, `tier`, `visibility`, `color` y `role`;
  - `periods`: `[{periodId, name, tier, frozen, played, goals, assists, mvps,
    hatTricks, flag}]`;
  - `totals`.
- `totals`: `all` y `trusted` (solo los períodos oficiales o verificados).
- `index`: el Índice Furbo.
- `trophies`: los premios de torneos (§7.6).

**Reglas de visibilidad**, por cada membresía:
- Si el servidor tiene `shareStats = false`, se omite, salvo para mí mismo.
- Si el servidor es privado, quien mira no es miembro y el jugador tiene
  `showPrivateStats = false`, se omite.
- Si el servidor es privado y quien mira no es miembro, va sin nombre.

### Otras rutas

- **`GET /players?q=`:** busca por usuario o nombre (mínimo 2 letras, hasta 20
  resultados).
- **`PATCH /me {showPrivateStats}`:** cambia el ajuste (columna nueva
  `users.show_private_stats`, por defecto 1).

### En la app

- El perfil de un miembro con cuenta tiene una sección **"En toda la app"**:
  - Es lo único del perfil que necesita conexión.
  - Lleva una tarjeta por servidor con su nivel, las temporadas desplegables,
    los totales "Todo" y "En servidores de prestigio" y el Índice Furbo.
  - Abajo, la vitrina de trofeos.
  - Si no hay señal, sale "Sin conexión: esto se ve cuando haya señal".
  - Lo último que se vio queda guardado en memoria mientras la app está
    abierta.
- La pantalla de jugador global se abre:
  - desde "Buscar jugadores" en el directorio;
  - desde una solicitud de entrada, para que el admin vea a quién acepta.

## 6. Directorio y solicitudes de entrada

### Rutas (todas necesitan conexión)

- **`GET /directory?q=&province=&kind=&cursor=`:** servidores y torneos
  públicos y activos.
  - Orden: oficiales primero, luego por nivel y luego por última jornada.
  - Cada uno lleva: `id`, `name`, `kind`, `province`, `city`, `color`,
    `official`, `tier`, `members`, `playDays`, `lastPlayedAt`, `joinPolicy` y
    `myStatus` (`member` / `pending` / `none`).
  - Los torneos llevan además `status` y si la inscripción está abierta.
- **`GET /directory/:clubId`:** el detalle de uno.
  - Para un servidor: descripción, los 5 mejores goleadores de la temporada
    activa (de `member_stats`) y las próximas 3 jornadas (fecha y terreno).
  - Para un torneo: equipos, formato y el campeón si ya terminó.
- **`POST /clubs/:id/join {message}`:** pedir entrar.
  - Público y abierto: entra al momento como `player`.
  - Público con solicitud: crea una solicitud pendiente.
  - Expulsado: `banned_from_club`.
  - Privado o no existe: 404.
  - Como mucho 5 solicitudes pendientes por persona.
- **`DELETE /clubs/:id/join`:** retirar la solicitud.
- **`GET /clubs/:id/join-requests`** (owner y admin): las pendientes, con
  usuario, nombre, mensaje y un resumen de su perfil global.
- **`POST /clubs/:id/join-requests/:rid/accept|reject {note}`.**

### La tabla

`join_requests`:
- **Columnas:** `id`, `club_id`, `user_id`, `message`, `status`
  (`pending`/`accepted`/`rejected`/`cancelled`), `decided_by`, `note`,
  `created_at` y `decided_at`.
- **Restricción:** una sola pendiente por `(club_id, user_id)`.

### `/me` añade

- `joinRequests`: las mías pendientes y las rechazadas de los últimos 30 días.
- `pendingJoinRequests`: `{clubId: n}` de los servidores donde soy owner o
  admin.

### Avisos nuevos

- Para admins: "2 personas quieren entrar en Los Pinos".
- Para quien pidió entrar: "¡Entraste en Los Pinos!" (el servidor aparece en
  `/me` y la solicitud estaba aceptada) y "No te aceptaron en Los Pinos".

### Páginas web públicas

Las sirve el Worker, como la de invitación: HTML ligero con el escape de
siempre.

- **`/s/:clubId`** (solo servidores públicos):
  - nombre, nivel, provincia y descripción;
  - la tabla de goleadores de la temporada;
  - la próxima jornada;
  - botones "Pedir entrar" (`elfurbo://club/<id>`) y "Descargar El Furbo".
- **`/t/:clubId`** (solo torneos públicos): ver §7.7.
- Un servidor privado o que no existe da la misma página de "no está".

### En la app

- **Pantalla "Buscar servidores"**, con pestañas Servidores, Torneos y
  Jugadores:
  - filtro por provincia;
  - buscador;
  - una tarjeta por resultado.
- **Detalle de un servidor**, con el botón "Pedir entrar" o "Entrar".
- **El admin ve las solicitudes en Admin → Miembros**, con el perfil global de
  cada uno.
- **El dueño elige en los ajustes:**
  - privado o público;
  - con solicitud o abierto;
  - la provincia y la ciudad;
  - el color;
  - si comparte estadísticas.

## 7. Torneos

### 7.1 Modelo

- **Un torneo es un `club`:**
  - `kind = 'tournament'`;
  - `host_club_id` es el servidor anfitrión;
  - nace `active`;
  - su owner es quien lo creó.
- **Roles:**
  - owner y admin organizan;
  - scorer es el anotador o árbitro;
  - player es jugador;
  - guest es un jugador sin cuenta (lo crea el staff, como hoy).
- **Lo que solo es de grupos se rechaza en un torneo**, con `wrong_kind`:
  temporadas, jornadas, asistencia, reportes y MVP de jornada.

Tablas nuevas (migración del PR5). Todas llevan `club_id` y viajan en el pull.

**`tournaments`** (una fila por torneo, clave `club_id`):
- **Configuración:**
  - `format`: `league`, `cup` o `groups_cup`;
  - `rules` (JSON).
- **Estado:** `status`, que pasa de `draft` a `registration`, luego a
  `in_progress` y termina en `finished`.
- **Inscripción y fechas:**
  - `registration_closes_at`;
  - `starts_on`;
  - `max_teams`, de 2 a 32.
- **Plantillas:** `min_players` y `max_players`, de 1 a 30.
- **Fechas de la fila:** `created_at` y `updated_at`.

`rules`, con sus valores por defecto:
```json
{ "pointsWin": 3, "pointsDraw": 1, "pointsLoss": 0,
  "legs": 1, "groups": 2, "advancePerGroup": 2, "thirdPlace": false,
  "tiebreakers": ["points", "goalDiff", "goalsFor", "headToHead", "fairPlay"],
  "yellowsForBan": 3, "redBanMatches": 1,
  "playersOnField": 7, "matchMinutes": 50, "knockoutTies": "penalties" }
```

**`teams`:**
- **Datos del equipo:**
  - `id` y `club_id`;
  - `name` (de 2 a 30 caracteres) y `short_name` (3 letras);
  - `color` (0–7).
- **Quién lo lleva:** `captain_member_id`.
- **A qué servidor representa:** `represents_club_id` (opcional).
- **Estado:** `status` (`pending`/`approved`/`withdrawn`).
- **Sorteo:** `seed` y `group_label`.
- **Fechas de la fila:** `created_at` y `updated_at`.

**`team_players`:**
- **Columnas:** `id` (`equipo:miembro`), `club_id`, `team_id`, `member_id`,
  `shirt` (0–99 o null), `status` (`active`/`removed`) y `updated_at`.
- **Regla:** un miembro está como mucho en un equipo activo por torneo.

**`fixtures`** (los partidos):
- **Fase:**
  - `id` y `club_id`;
  - `stage` (`league`/`group`/`knockout`/`third`);
  - `round`, `group_label` y `leg`;
  - `slot`: su posición en el cuadro.
- **Equipos:**
  - `home_team_id` y `away_team_id` (null mientras no se sabe);
  - `home_source` y `away_source` (JSON): `{winnerOf}`, `{loserOf}` o
    `{group, pos}`.
- **Programación:** `starts_at`, `place` y `scorer_member_id` (quién lo anota).
- **Estado:** `status` (`scheduled`/`played`/`cancelled`/`walkover`).
- **Resultado:**
  - `home_score` y `away_score`;
  - `home_pens` y `away_pens`;
  - `walkover_winner`.
- **Quién lo puso y cuándo:** `result_by`, `result_at` y `updated_at`.

**`fixture_events`:**
- **Columnas:** `id`, `club_id`, `fixture_id`, `team_id`, `member_id`, `kind`,
  `assist_member_id`, `minute` y `updated_at`.
- **`kind`:** `goal`, `own_goal`, `yellow`, `red` o `mvp`.

**`fixture_lineups`:**
- **Columnas:** `id` (`partido:miembro`), `club_id`, `fixture_id`, `team_id` y
  `member_id`.
- **Para qué:** dice quién jugó cada partido.

**`awards`:**
- **Columnas:** `id`, `club_id`, `kind`, `team_id`, `member_id`, `value` y
  `created_at`.
- **`kind`:** `champion`, `runner_up`, `third`, `top_scorer`, `top_assists`,
  `best_player` o `fair_play`.

### 7.2 Crear un torneo y entrar

**Crear** (con conexión), desde Admin del anfitrión: "Organizar un torneo".
- **Ruta:** `POST /clubs/:hostId/tournaments {name, description, format,
  visibility}`.
- **Qué crea:**
  - el `club`;
  - el miembro owner;
  - la fila `tournaments` en `draft`.
- **Requisitos:**
  - el anfitrión está activo;
  - quien lo crea es owner o admin del anfitrión;
  - el anfitrión tiene menos de 3 torneos sin terminar.

**Inscribir un equipo** (con conexión), en un torneo público con la inscripción
abierta.
- **Ruta:** `POST /tournaments/:id/teams {name, shortName, color,
  representsClubId?}`.
- **Qué hace:**
  - hace miembro (`player`) a quien lo pide;
  - crea el equipo `pending` con él de capitán.
- **Representar a un servidor:** solo si el capitán es miembro activo de ese
  servidor.

**Invitación de equipo:**
- Es una invitación con `team_id` (columna nueva en `invites`).
- La crean:
  - el capitán de ese equipo (siempre como `player`, durante la inscripción);
  - los organizadores.
- Al aceptarla, el miembro entra en el torneo y en el equipo, si la plantilla
  no está llena.

**Los organizadores también pueden:**
- crear equipos ellos mismos;
- añadir jugadores sin cuenta;
- invitar a gente por invitación normal (sin equipo).

### 7.3 Comandos de torneo

Todos van por la cola de siempre y se pueden hacer sin conexión.

| comando | quién |
|---------|-------|
| `tournament.update {format?, rules?, registrationClosesAt?, startsOn?, maxTeams?, minPlayers?, maxPlayers?, status?}` | organizadores. `status` solo avanza (`draft`→`registration`→`in_progress`) |
| `team.create {id, name, shortName, color, captainMemberId?, representsClubId?}` | organizadores (aprobado al momento) o cualquier miembro con cuenta durante la inscripción (pendiente, y él de capitán) |
| `team.update {teamId, name?, shortName?, color?, captainMemberId?}` | capitán u organizadores |
| `team.setStatus {teamId, status}` | organizadores; el capitán solo puede retirar el suyo durante la inscripción |
| `team.addPlayer {teamId, memberId, shirt?}` / `team.removePlayer` / `team.setShirt` | capitán (durante la inscripción) u organizadores |
| `fixtures.generate {stage, fixtures: [...]}` | organizadores: la app genera el calendario y el servidor comprueba equipos y forma |
| `fixtures.clear {stage}` | organizadores, si no hay ningún resultado en esa fase |
| `fixture.schedule {fixtureId, startsAt?, place?, scorerMemberId?}` | organizadores |
| `fixture.result {fixtureId, homeScore, awayScore, homePens?, awayPens?, events, lineups}` | el anotador del partido, o staff |
| `fixture.setStatus {fixtureId, status, walkoverWinner?}` | organizadores |
| `stage.advance {assignments: [{fixtureId, homeTeamId, awayTeamId}]}` | organizadores: de los grupos al cuadro |
| `tournament.finish {awards: [...]}` / `tournament.reopen` | organizadores |

**`fixture.result`:**
- Reemplaza los eventos y la alineación del partido.
- Si trae goles, tienen que sumar el marcador. Un `own_goal` cuenta para el
  rival.
- Los jugadores tienen que estar en la plantilla activa de su equipo.
- En eliminatorias, un empate necesita penales distintos.
- Al guardar un resultado de eliminatoria, el servidor pone al ganador (o al
  perdedor, para el tercer puesto) en los partidos que dependen de él (`winnerOf`
  / `loserOf`) y escribe sus cambios. El reductor de Dart hace lo mismo para la
  vista sin conexión.
- Caso compartido: `shared-fixtures/knockout.json`.

**Un torneo `finished` no acepta cambios** salvo `tournament.reopen`.

### 7.4 Calendario

Lo genera la app (Dart puro, `lib/domain/tournament/`), con tests:
- **Liga:** todos contra todos con el método del círculo, a una o dos vueltas,
  con descanso si los equipos son impares.
- **Copa:** cuadro de eliminación directa con cabezas de serie. Si los equipos
  no son potencia de 2, los mejores sembrados pasan la primera ronda sin jugar.
  Lleva tercer puesto opcional.
- **Grupos y copa:**
  - reparto en grupos por bombos (`seed`) y, en cada grupo, todos contra
    todos;
  - el cuadro se arma con `{group, pos}`: 1.º A contra 2.º B, etc.;
  - al terminar los grupos, "Cerrar grupos" calcula las tablas y manda
    `stage.advance`.

Las fechas se reparten desde `starts_on`, una ronda por semana. Se pueden mover
a mano con `fixture.schedule`.

### 7.5 Tablas, cuadro y sanciones

Todo se calcula en el teléfono a partir de los partidos.

- **Tabla:**
  - columnas PJ, G, E, P, GF, GC, DG y Pts;
  - desempate en el orden de `tiebreakers`;
  - `headToHead` mira solo los partidos entre los empatados;
  - `fairPlay` resta 1 por amarilla y 3 por roja;
  - si siguen empatados, el `seed` y luego el nombre.
- **Puerto en TypeScript:** `backend/src/rules/standings.ts`, para las páginas
  web, con casos en `shared-fixtures/standings.json`.
- **Cuadro:** columnas por ronda, con líneas de tiza. El ganador va en negrita y
  los penales entre paréntesis.
- **Sanciones automáticas:**
  - `yellowsForBan` amarillas acumuladas suspenden el partido siguiente de su
    equipo, y el contador vuelve a empezar;
  - una roja suspende `redBanMatches` partidos.
  - Sale "Suspendido" en la plantilla y en la alineación del partido.
- **Goleadores y asistentes** del torneo, y las estadísticas por equipo.

### 7.6 Final, premios y vitrina

"Terminar el torneo" propone los premios y el organizador los confirma:

| premio | cómo se propone |
|--------|-----------------|
| Campeón y subcampeón | de la final (copa) o la tabla (liga) |
| Tercer puesto | si se jugó |
| Bota de oro | el que más goles hizo |
| Más asistencias | el que más asistencias dio |
| Mejor jugador | el que más MVP de partido tiene; el organizador puede elegir otro |
| Fair play | el equipo con menos tarjetas |

- Se guardan en `awards`.
- El perfil global los muestra en la **vitrina**: "🏆 Campeón · Copa Verano
  2026".
- Para que un premio de equipo salga en el perfil de un jugador, tiene que
  estar en la plantilla activa del equipo.

### 7.7 Estadísticas, prestigio y web

- **`member_stats` de un torneo** (período = el torneo):
  - `played`: las alineaciones;
  - goles, asistencias, MVP y tarjetas: los eventos.
- **Prestigio:** el nivel del torneo sigue §4.
- **Página `/t/:clubId`** (solo torneos públicos):
  - la tabla o el cuadro;
  - los últimos resultados;
  - los goleadores;
  - el campeón.
  - Pensada para compartirla por WhatsApp.
- **Directorio:** pestaña Torneos, con "Inscripción abierta" cuando toca.

### 7.8 Pantallas de un torneo

El mismo shell, con otras pestañas:

- **Partidos:**
  - por ronda;
  - "Mi equipo" arriba;
  - el que me toca anotar, marcado.
  - Al tocar un partido:
    - se ve el detalle con los eventos;
    - si soy anotador o staff, "Poner resultado": marcador, quién jugó, goles
      con su asistencia, tarjetas y MVP.
- **Tabla:** la tabla o el cuadro (con selector si hay grupos y cuadro). Abajo,
  goleadores.
- **Equipos:**
  - la lista;
  - el detalle con la plantilla, el capitán y "Invitar a mi equipo";
  - "Inscribir un equipo" si la inscripción está abierta.
- **Perfil:** mis números en el torneo y los premios.
- **Admin:**
  - la configuración (formato, reglas, fechas y plantillas);
  - las inscripciones (aprobar y retirar);
  - "Generar calendario";
  - programar los partidos y asignar anotadores;
  - "Cerrar grupos";
  - "Terminar torneo";
  - miembros e invitaciones, como en un servidor.

## 8. Extras de la 2.0

### 8.1 Comprobar asistencia con código

- **El código:**
  - El staff abre en la jornada "Código de asistencia" y ve 6 cifras que
    cambian cada 5 minutos.
  - Es TOTP con HMAC-SHA256: el secreto del servidor y la ventana
    `floor(t/300)`, sin conexión.
  - El secreto lo pide el staff una vez con conexión
    (`GET /clubs/:id/checkin-secret`; si no existe, se crea) y queda guardado
    en su teléfono.
  - El secreto nunca viaja en el pull.
- **El jugador:**
  - Toca "Estoy aquí" y escribe el código.
  - Eso va como `attendance.checkIn {matchdayId, code}`, que marca `played` y
    `checked_in_at`.
- **El servidor comprueba:**
  - que el código coincide con la ventana de `clientAt` o con la de al lado;
  - que la jornada empieza en ±3 horas de `clientAt`.
- **Para qué sirve:**
  - cuenta para el prestigio (§4);
  - en la lista de la jornada sale un ✓ junto a quien la comprobó.

### 8.2 Cupo y lista de espera

- **Columnas nuevas:**
  - `max_players` en `matchdays`: 0 es sin límite. Por defecto es el
    `maxPlayers` del servidor, y se cambia al crear o editar la jornada.
  - `intent_at` en `attendance`, con la hora del servidor de cada "Voy".
- **Cómo se reparte:**
  - Los primeros `max_players` por `intent_at` están **dentro**.
  - El resto, **en espera**, con su número.
  - Si alguien se baja, sube el siguiente. Se calcula en la vista, no se guarda.
- **Aviso nuevo:** "¡Entraste! Se liberó un cupo para el sábado" (si estabas
  en espera y ahora estás dentro).

### 8.3 Carta del jugador

- La tarjeta para WhatsApp pasa a ser una **carta**:
  - nombre y apodo;
  - nivel del servidor;
  - PJ, goles, asistencias y MVP de la temporada;
  - su posición en la tabla;
  - el Índice Furbo, si se conoce.
- Se comparte como imagen.

### 8.4 Resumen de temporada

Al cerrar una temporada, el perfil ofrece "Tu temporada". Es una pantalla para
compartir con:
- las jornadas y la mejor racha;
- los goles, las asistencias y los MVP;
- el mejor día;
- la posición en la tabla;
- el compañero con quien más veces le tocó en el mismo equipo, si se guardaron
  equipos.

### 8.5 Récords del servidor

Una sección "Récords" en la Tabla:
- más goles en una jornada;
- más goles en una temporada;
- la racha más larga;
- más MVP en una temporada;
- más jornadas seguidas.

Cada uno con quién lo tiene y cuándo.

## 9. Compatibilidad y versión

- **La versión:** la 2.0.0 sube `MIN_SUPPORTED_BUILD` a su build. Una 1.x no
  entiende los torneos ni las entidades nuevas del pull. Hay pocos usuarios y
  todos actualizan desde la app.
- **Hasta la release:**
  - los PRs se despliegan a staging solos;
  - producción se despliega a mano al publicar la 2.0.0.
- **El modelo de grupos no cambia:** las columnas nuevas tienen valores por
  defecto y la 1.x sigue funcionando contra un backend 2.0 hasta que se suba
  `MIN_SUPPORTED_BUILD`.

## 10. Pruebas

Lo mismo que la 1.0:
- vitest con D1 local;
- `flutter test`;
- `shared-fixtures`.

Además:
- **Stats:** los casos compartidos de stats, standings y eliminatorias, en los
  dos lados.
- **Permisos:**
  - la matriz de los comandos de torneo;
  - un torneo rechaza los comandos de grupo y al revés.
- **Privacidad del perfil global:** público, privado, `shareStats`,
  `showPrivateStats` y quien mira siendo miembro.
- **Directorio:** solo salen los públicos y activos; los privados dan 404 al
  pedir entrar.
- **Prestigio:** las señales y los niveles con datos de prueba, y que se
  congelan al cerrar.
- **Generadores de calendario** (Dart): número de partidos, que nadie juegue
  dos veces en la misma ronda, descansos y cuadros con exentos.

## 11. Orden de entrega (PRs)

1. **Cambiar de servidor e identidad:**
   - migración de `clubs`;
   - `club.updateProfile` y `club.setVisibility`;
   - oficial y sacar del directorio desde el superadmin;
   - pull ampliado;
   - la hoja de servidores con color y números de pendientes;
   - la agenda;
   - el perfil del servidor en los ajustes.
2. **Estadísticas y prestigio en el backend:**
   - `rules/stats.ts` y los casos compartidos;
   - `member_stats`, `club_metrics` y `period_tiers`;
   - el cálculo en el cron;
   - los niveles en la app y "qué le falta" en los ajustes.
3. **Perfil global:** `/players` y la búsqueda, la privacidad, la sección "En
   toda la app" y el Índice Furbo.
4. **Directorio y solicitudes:** `/directory`, `join_requests`, avisos y la
   página `/s/:id`.
5. **Torneos I:**
   - el modelo;
   - crear un torneo;
   - equipos, plantillas e invitaciones de equipo;
   - el shell de torneo con Equipos y Admin.
6. **Torneos II:**
   - los generadores de calendario;
   - resultados con eventos y alineación;
   - la tabla y el cuadro;
   - sanciones y goleadores;
   - pasar de grupos al cuadro.
7. **Torneos III:**
   - final y premios, y la vitrina;
   - estadísticas y prestigio del torneo;
   - la página `/t/:id`;
   - torneos en el directorio.
8. **Extras:** código de asistencia, cupo y lista de espera, carta, resumen de
   temporada y récords.
9. **2.0.0:** `MIN_SUPPORTED_BUILD`, README, desplegar a producción y la
   release.

## Después de la 2.0

- **Pagos del terreno:** quién pagó y quién debe.
- **"Falta uno":** avisar a jugadores sueltos de servidores públicos cerca.
- **Retos entre servidores:** un amistoso que se acepta y se vuelve un torneo
  de un partido.
- **Resultado por equipo en la jornada:** con eso salen un ELO y las parejas
  que más ganan.
- **Más superficies:** widget de Android y una versión web o PWA para iPhone.
- **Más formatos:** sistema suizo, doble eliminación y ligas que se repiten por
  temporadas.
