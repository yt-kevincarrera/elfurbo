# El Furbo: jornadas, presencia real, cierre y notificaciones sin Blaze

Fecha: 2026-09-14. Estado: aprobado por el dueño del proyecto.

## Contexto

El grupo juega muchos partidos cortos (a un gol) con equipos que rotan dentro
de un mismo encuentro. La unidad de registro es por tanto la **jornada** (el
día que se juntan), no el partido. Cada jugador reporta sus goles y
asistencias totales de la jornada. No se registra marcador ni resultado.

Este documento define los cambios aprobados sobre la app existente. Los
nombres internos (`matches`, `MatchDay`, `matchId`) se conservan para no
migrar datos; cambia el lenguaje visible.

## 1. Jornada

- Todo texto visible y notificación dice "jornada" en vez de "partido":
  pestaña "Jornadas", "Nueva jornada", "¿Jugaste esta jornada?", etc.
- Nuevo campo `durationMinutes` (int, por defecto 120, editable en el
  formulario). Derivados en `MatchDay`:
  - `isUpcoming(now)`: `now < date` y no cancelada.
  - `isInProgress(now)`: `date <= now < date + duration` y no cancelada.
  - `isPlayed(now)`: `now >= date + duration` y no cancelada.
- Lista de jornadas: secciones "Próximas" (incluye en curso, con etiqueta
  "En curso") y "Jugadas". Las canceladas van a la sección que corresponde
  por fecha, tachadas.
- Al abrir una jornada, la pestaña inicial es Asistencia si no se jugó y
  Goles si ya se jugó.

## 2. Cierre de jornada y temporada

- `status` de la jornada: `scheduled | cancelled | closed | reopened`.
  - `closed`: cerrada por el admin.
  - `reopened`: el admin la forzó abierta; solo se cierra a mano.
- `isClosed(now)`: `status == closed`, o `status == scheduled` y
  `now >= date + 72h`, o su temporada está cerrada.
- Cerrada: no se aceptan reportes (crear, editar, borrar), confirmaciones,
  decisiones del admin sobre reportes, votos ni cambios de presencia. La UI
  lo muestra con un banner "Jornada cerrada" y deshabilita acciones. Las
  reglas de Firestore lo hacen cumplir con `get()` de la jornada y
  `request.time`.
- El admin tiene "Cerrar ahora" y "Reabrir" en el menú de la jornada.
- Temporada: nuevo campo `isClosed` (bool). Menú del admin: "Cerrar
  temporada" / "Reabrir temporada". La tabla muestra "(cerrada)" en la
  etiqueta del período. Una temporada cerrada no puede ser la activa.

## 3. Presencia real

Documento `attendance/{matchId_uid}`:

| campo         | tipo             | significado                                       |
|---------------|------------------|---------------------------------------------------|
| `status`      | yes/no/maybe     | intención antes de la jornada (sin cambios)       |
| `played`      | bool? (null)     | presencia real; null = sin confirmar              |
| `playedSetBy` | string?          | uid de quien la marcó (el propio o un admin)      |
| `updatedAt`   | timestamp        |                                                   |

- Antes de jugarse: solo se edita `status`. Equipos usa `status == yes`.
- Jugada: el botón propio pasa a "Jugué / No fui" y escribe `played`.
  Enviar un reporte escribe `played = true`. `status` ya no cuenta.
- Admin: "Pasar lista" (hoja con todos los jugadores activos, prellenada con
  `played == true` y, si es null, con `status == yes`); guarda en lote
  `played` y `playedSetBy = admin`.
- `StatsEngine.playersInMatch` = `played == true` o reporte confirmado.
  Deja de mirar `status`. Partidos jugados, rachas, logro Fiel, candidatos a
  MVP, quién puede confirmar y quién puede votar usan solo presencia real.
- Reglas: el propio usuario solo puede escribir `played` cuando la jornada
  ya se jugó y no está cerrada; el admin siempre (salvo cerrada, que también
  lo frena salvo que la reabra).

## 4. Reportes y MVP

- Rechazo definitivo: si `adminStatus == rejected`, el autor no puede
  editar ni borrar el reporte (regla y UI). Solo el admin puede "Quitar
  decisión" para devolverlo a pendiente.
- Corrección del admin: acción "Corregir" que abre el formulario con los
  números actuales y guarda `goals`, `assists`, `adminStatus = confirmed`,
  `correctedBy = uid admin`. La UI muestra "Corregido por el admin".
- Edición de un reporte confirmado: la Function `onReportUpdated` detecta
  confirmado → pendiente y avisa a los presentes "X editó su reporte,
  vuelve a confirmarlo".
- MVP: `mvpWinners` desempata por goles confirmados de la jornada, luego
  asistencias confirmadas; si persiste, comparten. Votar exige presencia
  real del votante y del votado.

## 5. CRUD del admin

Jornadas:
- Crear con fecha, hora, duración, lugar, notas, temporada (por defecto la
  activa; lista desplegable) y "Repetir cada semana" con cantidad de
  semanas (1 a 26). Se crean N documentos en un lote.
- Editar (mismos campos incluida la temporada), cancelar/reactivar, cerrar/
  reabrir, eliminar. Eliminar borra en lote la jornada y todas sus
  asistencias, reportes y votos (se toman de las colecciones ya cargadas).

Temporadas:
- Crear (nombre, fecha de inicio, activar), renombrar, editar fecha de
  inicio, activar, cerrar/reabrir, eliminar (solo si no tiene jornadas;
  si no, la UI ofrece mover las jornadas a otra temporada primero).

Usuarios:
- No se puede quitar el rol ni bloquear al último admin activo (UI). Las
  reglas impiden que un admin se quite a sí mismo el rol si es el único:
  no es verificable en reglas, por lo que se documenta como límite y se
  guarda en la UI.

## 6. Notificaciones

- Tokens: `fcmTokens` (array de strings) en `users`. La app hace
  `arrayUnion` al registrar y `arrayRemove` + `deleteToken()` al cerrar
  sesión. Las Functions envían a todos y limpian los muertos. Se mantiene
  compatibilidad leyendo `fcmToken` viejo si existe.
- Canal Android `elfurbo_default` "El Furbo" creado al iniciar con
  `flutter_local_notifications`.
- Tocar una notificación abre la jornada (`data.matchId`) o la pestaña
  Admin (`type == pending_user`). Se usa un `GlobalKey<NavigatorState>`.
  Cubre push en frío y en caliente, y notificaciones locales.
- Sin Blaze (todo local, reutilizando el worker existente cada 12 h):
  - Admin: cantidad de usuarios pendientes → "N jugadores esperando".
  - Jugador presente en una jornada abierta: reportes ajenos pendientes que
    aún no confirmó → "Tienes N reportes para confirmar".
  - Recordatorios programados con `zonedSchedule` al abrir la app para las
    próximas jornadas: 09:00 del día ("¡Hoy se juega!") y 22:00 ("¿Cuántos
    metiste hoy?"). Se reprograman en cada apertura; se cancelan al salir.
  - El worker inicializa Firebase en su isolate y usa la sesión persistida.
- Con Blaze: el recordatorio de las 09:00 excluye a quien marcó "No voy".

## 7. Cuenta y pulido

- "Eliminar mi cuenta" en el menú del perfil: borra `users/{uid}` (regla
  `delete` propia) y la cuenta de Firebase Auth (reautentica con Google si
  hace falta). El historial queda; los nombres se muestran como "Jugador".
- El banner de sin conexión espera al primer snapshot del servidor o 3 s.
- Si falla la creación del perfil, la pantalla de espera ofrece
  "Reintentar".
- Reglas: no se puede crear asistencia, reporte ni voto para una jornada
  cancelada ni para una que aún no se jugó (salvo la intención `status`).

## 8. Tests y CI

- Dart: `MatchDay` (en curso / jugada / cerrada), `StatsEngine` con
  presencia real, desempate de MVP, generación de jornadas recurrentes,
  borrado en cascada (construcción del lote).
- Reglas: `firestore-tests/` con `@firebase/rules-unit-testing` y el
  emulador: casos de cierre, rechazo definitivo, presencia, último token.
- GitHub Actions `.github/workflows/ci.yml`: `flutter analyze`,
  `flutter test`, y tests de reglas con el emulador en cada PR y en `main`.

## Fuera de alcance

Marcador o resultado de partidos, estadísticas adicionales (autogoles,
atajadas, tarjetas), soporte iOS.

## Orden de entrega

1. Jornadas, duración, cierre, recurrencia, CRUD de temporadas, borrado en
   cascada, guardarraíl de último admin.
2. Presencia real y pasar lista.
3. Reportes (rechazo, corrección, aviso de edición) y desempate de MVP.
4. Notificaciones: tokens, canal, navegación, recordatorios y chequeos
   locales.
5. Cuenta y pulido.
6. Tests de reglas y CI.
