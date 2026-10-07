# El Furbo ⚽

App Android para los grupos que juegan fútbol: cada uno carga sus goles y asistencias después
de cada jornada, los compañeros (o el staff) confirman que es verdad, y las estadísticas se
acumulan jornada a jornada. Se juegan muchos partidos cortos con equipos que rotan, así que la
unidad es la jornada, no el partido, y no se registran marcadores.

Pensada para Cuba: **no usa nada de Google** (desde allí Firebase y GitHub no abren sin VPN).
El backend es propio, en Cloudflare, que sí responde desde ETECSA. Todo funciona **sin
internet** y se sincroniza solo cuando vuelve la señal, también con la app cerrada.

## Qué hace

| | |
| --- | --- |
| **Servidores** | Cada grupo es un servidor. Cualquiera lo solicita y el superadmin lo aprueba. Se entra por invitación (enlace o código), con roles: dueño, admin, anotador y jugador. Hay jugadores sin cuenta que después reclaman su perfil. |
| **Jornadas** | Fecha, hora, cancha y temporada, sin duración fija. Se editan, cancelan, cierran, reabren o borran. Se cierran solas pasado el plazo del servidor (72 h por defecto). |
| **Asistencia** | Antes, *Voy / Quizás / No voy*. Después, *Jugué*. |
| **Reportes** | Cada uno carga sus goles y asistencias. Cuentan con las confirmaciones de los que jugaron (2 por defecto), en modo confianza al momento, o con el staff. |
| **MVP, tabla y perfil** | Votación del mejor; ranking por temporada o histórico; perfil con evolución, logros y rachas. |
| **Equipos parejos** | Propone dos equipos balanceados con los que van. |
| **Avisos** | Jornada nueva, reportes por confirmar, reporte rechazado y servidor aprobado. Los calcula el teléfono cuando sincroniza, sin push. Recordatorios de "¡Hoy se juega!" y "¿Cuántos metiste hoy?". |
| **Actualizaciones** | La app baja las versiones nuevas desde nuestro servidor, que las lee de GitHub. Si la descarga se corta, sigue donde se quedó. |

## Stack

- **App:** Flutter (Android), Riverpod, WorkManager para el sync en segundo plano y avisos locales.
  Las reglas y estadísticas son Dart puro, en `lib/domain/` y `lib/cloud/rules/`, con tests.
- **Backend** (`backend/`): Cloudflare Workers + D1 + Hono, en el plan gratuito. Diseño completo:
  `docs/superpowers/specs/2026-10-01-servidores-backend-propio-design.md`.
- **Sync:** cola de comandos en el teléfono (un archivo por cambio), `POST /sync/push` y
  `POST /sync/pull` incremental. La vista es el último estado del servidor con lo pendiente
  encima. Los contratos compartidos están en `shared-fixtures/`, probados desde Dart y TypeScript.

## Entornos

| | URL | D1 |
| --- | --- | --- |
| Producción (la app publicada) | `https://furbo-api.furbo-probe.workers.dev` | `furbo-prod` |
| Staging | `https://furbo-api-staging.furbo-probe.workers.dev` | `furbo-staging` |

## Desarrollo

Requisitos: Flutter 3.41, Node 22 y **npm 11** (con npm 10 falla la instalación del backend:
`npm install -g npm@11`).

```bash
flutter pub get
flutter run --dart-define=API_URL=https://furbo-api-staging.furbo-probe.workers.dev   # contra staging

cd backend
npm ci
npm test              # tests dentro del runtime de Workers, con D1 local
npm run typecheck
npm run dev           # API local en http://localhost:8787 (antes: npm run db:migrate:local)
```

Sin `--dart-define`, la app habla con producción.

### Desplegar el backend

```bash
cd backend
npm run deploy:staging      # migraciones + Worker (el CI lo hace solo en cada push a main)
npm run deploy:production   # a mano, cuando staging está probado
```

Requiere `npx wrangler login`. El CI usa los secretos `CLOUDFLARE_API_TOKEN` y `CLOUDFLARE_ACCOUNT_ID`.

Opcional: `npx wrangler secret put GITHUB_TOKEN --env production` (un token de solo lectura).
Sin él, GitHub limita a 60 consultas por hora la IP compartida de Cloudflare. Aun así, el
servidor guarda la última release que vio.

### Firmar las releases

Las releases se firman con una clave propia que **no está en el repo**. Si se pierde, los
teléfonos no aceptan la siguiente versión encima y hay que desinstalar. Guárdala con su
contraseña en un sitio seguro.

```bash
keytool -genkeypair -v -keystore ~/elfurbo-release.jks -alias elfurbo -keyalg RSA -keysize 4096 -validity 10000
```

Después crea `android/key.properties` (está en `.gitignore`):

```properties
storeFile=C:/Users/<tú>/elfurbo-release.jks
storePassword=<la contraseña>
keyAlias=elfurbo
keyPassword=<la contraseña>
```

Sin ese archivo, `flutter build` firma con la clave de debug (sirve para probar) y
`tool/release.sh` se niega a publicar. Además comprueba que cada APK venga firmado con la
clave cuya huella está en `tool/release-cert.sha256`.

### Publicar una versión

```bash
tool/release.sh 1.0.0 --notes "Qué cambió"
```

El script:
1. Sube `version:` en `pubspec.yaml`.
2. Compila los APK por arquitectura.
3. Commitea y crea el tag.
4. Publica la release en GitHub con los APK.

Necesita `gh` con la cuenta dueña del repo. Desde ahí los teléfonos se enteran solos: el
servidor la ofrece en `/app/latest` (caché de 1 hora). Si un cambio del protocolo de sync
lo exige, sube `MIN_SUPPORTED_BUILD` en `backend/wrangler.jsonc`: las versiones más viejas
dejan de sincronizar y piden actualizar.

Para repartir la app a alguien nuevo basta el enlace de invitación: la página tiene
**Descargar El Furbo** (`/app/download`).

### Administrar

- **Marcarse superadmin** (a propósito, no se puede desde la API):

  ```bash
  cd backend && npx wrangler d1 execute DB --remote --env production --command "UPDATE users SET is_superadmin = 1 WHERE username = 'kevin'"
  ```

- **Copias de seguridad:** D1 Time Travel vuelve a cualquier minuto de los últimos 7 días (plan gratis)
  (`npx wrangler d1 time-travel restore DB --env production --timestamp=<ISO>`). Export
  manual: `npx wrangler d1 export DB --remote --env production --output=backup.sql`.
- **Purga:** un cron a las 08:00 UTC borra lo viejo de la sincronización (cambios de más de
  90 días, comandos aplicados de más de 30, sesiones caducadas).

## Tests y CI

- `flutter test` cubre:
  - estadísticas, logros y equipos;
  - reglas de jornada;
  - la cola y el sync (incluido el segundo plano a la vez que la app);
  - avisos, actualizaciones y pantallas.
- `cd backend && npm test`: las rutas, los comandos del sync, la purga y las rutas `/app`,
  contra D1 local.
- GitHub Actions (`.github/workflows/ci.yml`): formato, análisis y tests de Flutter; tipos y
  tests del backend; y despliegue a staging en cada push a `main`.

## Estructura

```
lib/
  main.dart, app.dart   arranque, sesión de un servidor (avisos, recordatorios, actualizaciones)
  cloud/                api, sesión, cola y sync, avisos, pantallas de cuenta y servidores
  data/                 providers de la vista del servidor y ClubRepo (escribe comandos)
  domain/, models/      reglas, estadísticas, logros y modelos
  services/             notificaciones, WorkManager, actualizaciones
  ui/                   pantallas de la pachanga, admin y superadmin
backend/                Worker (src/), migraciones de D1 y tests
shared-fixtures/        contratos y reglas que prueban la app y el backend
docs/                   spec, tono (docs/tono.md) y diseño "pizarra" (docs/diseno.md)
```
