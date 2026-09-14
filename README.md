# El Furbo ⚽

App Android para el grupo de amigos que juega al fútbol: cada uno carga sus goles y
asistencias después de cada jornada, los compañeros (o el admin) confirman que es verdad, y
las estadísticas se acumulan jornada a jornada. Se juegan muchos partidos cortos con equipos que rotan, así que la unidad es la jornada, no el partido, y no se registran marcadores. Funciona **sin internet** y sincroniza sola
cuando vuelve la conexión.

## Qué hace

| Feature | Cómo funciona |
| --- | --- |
| **Jornadas** | El admin crea jornadas con fecha, hora, duración (2 h por defecto), cancha y temporada, de a una o repetidas cada semana. Se pueden editar, cancelar, cerrar, reabrir o eliminar (con sus asistencias, reportes y votos). Una jornada está "en curso" entre su hora y hora + duración, y se cierra sola 72 h después de empezar: desde ahí no se aceptan goles, confirmaciones ni votos. |
| **Asistencia** | Antes de la jornada cada uno marca *Voy / Quizás / No voy*. Después, *Jugué*. |
| **Reportes** | Cada jugador carga sus goles y asistencias (y un comentario opcional). |
| **Confirmación** | Un reporte cuenta cuando lo confirman **2 compañeros que jugaron ese día** o **el admin**. El admin también puede rechazarlo. Si el autor edita el reporte, vuelve a pendiente. |
| **MVP** | Los que jugaron votan al mejor de la jornada. Si hay empate, todos los empatados suman MVP. |
| **Tabla** | Ranking por goles, asistencias, MVP y G+A. Filtrable por temporada o histórico total. |
| **Perfil** | Stats del jugador, posición en cada ranking, curva de evolución jornada a jornada, historial. Desde el menú: buscar actualizaciones, cerrar sesión y **eliminar mi cuenta** (borra perfil y acceso; el historial queda a nombre de "Jugador"). |
| **Logros y rachas** | Hat-trick, Póker, Goleador (10/50/100), Fiel (5/10/25 seguidos), MVP, Imparable, etc. Se recalculan siempre a partir de los datos. |
| **Equipos parejos** | Con los que marcaron que van, la app propone dos equipos balanceados por rendimiento histórico. "Mezclar de nuevo" da otra combinación igual de pareja. El admin los guarda. |
| **Compartir** | Tarjeta con goleadores, MVP y top 3 de la temporada, lista para mandar al grupo de WhatsApp. |
| **Temporadas** | El admin cierra el año y abre una temporada nueva. La tabla arranca de cero; el histórico se conserva. |
| **Notificaciones** | Hoy hay jornada → marca asistencia. Alguien reportó → confírmalo. Te confirmaron. Nuevo jugador esperando aprobación. |
| **Offline** | Firestore guarda todo en el teléfono. Puedes cargar goles en la cancha sin señal y se sube después. Una barra arriba avisa si estás offline o con cambios sin subir. |
| **Acceso** | Login con Google. El primer usuario que entra queda como admin; los siguientes esperan aprobación del admin. |

## Stack

- **Flutter** (Android) + **Riverpod** para estado + **fl_chart** para gráficos.
- **Firebase**: Authentication (Google), Cloud Firestore (con persistencia offline), Cloud Messaging (push) y Cloud Functions (Node 22) para enviar las notificaciones y auto-nombrar al primer admin.
- Toda la lógica de estadísticas, logros y balanceo de equipos está en `lib/domain/` en Dart puro, con tests en `test/`.

## Puesta en marcha

### 1. Requisitos

- [Flutter](https://docs.flutter.dev/get-started/install) 3.35 o superior (`flutter doctor` sin errores para Android).
- [Firebase CLI](https://firebase.google.com/docs/cli) (`npm i -g firebase-tools`) y Node 22 para las Cloud Functions.
- Una cuenta de Google para crear el proyecto de Firebase.

### 2. Crear el proyecto de Firebase

1. Entra a [console.firebase.google.com](https://console.firebase.google.com) y crea un proyecto (por ejemplo `elfurbo`).
2. **Agregar app → Android**. Nombre del paquete: `app.elfurbo` (tiene que coincidir con `applicationId` en `android/app/build.gradle.kts`).
3. Carga la **huella SHA-1** de tu clave de firma. Para la clave de debug:

   ```bash
   keytool -list -v -alias androiddebugkey -keystore ~/.android/debug.keystore -storepass android -keypass android
   ```

   Sin el SHA-1 correcto, el login con Google falla. Cuando firmes el APK de release con otra clave, agrega también ese SHA-1.
4. Descarga **`google-services.json`** y guárdalo en `android/app/google-services.json` (está en `.gitignore`; hay una plantilla en `google-services.json.example`).

### 3. Authentication

Firebase Console → **Authentication → Sign-in method → Google → Habilitar**. Pon un correo de soporte y guarda.

### 4. Firestore

1. **Firestore Database → Crear base de datos**, modo producción. Elige la región más cercana (este proyecto usa `nam5`).
2. Vincula el repo al proyecto y sube las reglas de seguridad:

   ```bash
   cp .firebaserc.example .firebaserc      # edita el project id
   firebase login
   firebase deploy --only firestore
   ```

   Las reglas (`firestore.rules`) son las que garantizan que nadie pueda confirmarse a sí mismo, inflar reportes ajenos o auto-nombrarse admin.

### 5. Cloud Functions (notificaciones)

Las notificaciones push y el "primer usuario es admin" corren en Cloud Functions. Requieren el plan **Blaze** (pago por uso; para un grupo de amigos queda en la franja gratuita).

```bash
cd functions
npm install
cd ..
firebase deploy --only functions
```

Antes de desplegar, revisa en `functions/index.js`:

- `REGION`: debe coincidir con la región de tu Firestore (o `us-central1` si elegiste una multi-región).
- `TIME_ZONE`: zona horaria del grupo para los recordatorios de las 09:00 y las 22:00.

> Si no quieres usar Functions, la app funciona igual y al primer admin lo tienes que marcar a mano (ver abajo). Sin Blaze no hay push entre teléfonos, pero la app avisa **localmente**: un trabajo en segundo plano cada 12 h revisa si hay jugadores esperando aprobación (admin) o reportes ajenos que te falta confirmar, y al abrirla programa recordatorios para las próximas jornadas (09:00 "¡Hoy se juega!" y 22:00 "¿Cuántos metiste hoy?", salvo que hayas dicho "No voy"). Tocar cualquier notificación abre la jornada o la pestaña Admin. Al cerrar sesión se borra el token de push del teléfono, así otro usuario que entre después no recibe tus avisos.

### 6. Compilar e instalar

```bash
flutter pub get
flutter run                  # con un teléfono conectado o un emulador
flutter build apk --release --split-per-abi  # un APK por arquitectura en build/app/outputs/flutter-apk/
```

El release se firma con la clave de debug de tu PC (la del SHA-1 que registraste), así que
compila siempre desde la misma máquina: Android solo instala una actualización si viene
firmada con la misma clave. Si prefieres una clave propia, sigue la
[guía oficial](https://docs.flutter.dev/deployment/android#signing-the-app) y carga también su SHA-1 en Firebase.

### 6b. Publicar actualizaciones (GitHub Releases)

La app se actualiza sola desde las releases de este repo (`/releases/latest`):

- Al abrirla con sesión activa consulta GitHub como mucho cada 12 h y, si hay una versión
  más nueva que la instalada, muestra un diálogo con las notas y un botón **Actualizar** que
  descarga el APK de la arquitectura del teléfono y abre el instalador de Android.
- Con la app cerrada, un `WorkManager` periódico (cada 12 h, con red) hace el mismo chequeo y
  avisa con una notificación local en el canal "Actualizaciones". Tocarla abre la app y el diálogo.
- En **Perfil → ⋮ → Buscar actualizaciones** se fuerza el chequeo a mano (ahí se ve la versión).

Para publicar una versión:

```bash
tool/release.sh 0.2.0 --notes "Qué cambió"
```

El script sube `version:` en `pubspec.yaml` (nombre X.Y.Z y `versionCode` +1, necesario para que
Android acepte la actualización), compila con `--split-per-abi`, commitea, crea el tag `vX.Y.Z` y
la release en GitHub con los tres APK adjuntos. Necesita `gh` logueado con la cuenta dueña del repo.
La primera vez Android va a pedir permitir "instalar apps desconocidas" a El Furbo.

### 7. Primer uso

1. Entra con tu Google. Si las Functions están desplegadas, **el primer usuario queda como admin activo automáticamente**.
   Si no, en Firebase Console → Firestore → colección `users` → tu documento, pon `role: "admin"` y `status: "active"`.
2. Cada amigo entra con su Google y te aparece en la pestaña **Admin → Pendientes**. Apruébalo con un toque.
3. Crea la primera jornada. Se genera sola una temporada (`Temporada 2026`). En Admin puedes crear, renombrar, editar, activar, cerrar (congela sus jornadas) y eliminar temporadas. No se puede quitar el rol al único admin.

## Modelo de datos (Firestore)

Todas las colecciones son de primer nivel para que las reglas sean simples y todo se cachee offline:

| Colección | Doc id | Contenido |
| --- | --- | --- |
| `users` | uid | `displayName`, `nickname`, `photoUrl`, `email`, `role` (`admin`/`player`), `status` (`pending`/`active`/`blocked`), `fcmToken` |
| `seasons` | auto | `name`, `startDate`, `isActive` |
| `matches` | auto | `date`, `seasonId`, `status` (`scheduled`/`cancelled`), `place`, `notes`, `teams.{a,b}`, `createdBy` |
| `attendance` | `{matchId}_{uid}` | `status` (`yes`/`no`/`maybe`) |
| `reports` | `{matchId}_{uid}` | `goals`, `assists`, `note`, `confirmations: [uid]`, `adminStatus` (`confirmed`/`rejected`/null) |
| `mvpVotes` | `{matchId}_{voterUid}` | `votedFor` |

Estado efectivo de un reporte: `adminStatus` si el admin decidió; si no, `confirmed` cuando
`confirmations` tiene 2 o más uids, `pending` en caso contrario. Se calcula en el cliente y en las
Functions con la misma regla, y las reglas de Firestore impiden agregar un uid que no sea el propio,
confirmarse a sí mismo o confirmar sin haber marcado asistencia.

## Estructura

```
lib/
  main.dart, app.dart        arranque, Firebase, tema, gate de sesión
  core/                      tema, formateo de fechas, snackbars globales
  models/                    AppUser, Season, MatchDay, Attendance, MatchReport, MvpVote
  data/                      FirestoreRepo (escrituras) y providers Riverpod (streams)
  domain/                    StatsEngine, Achievements, TeamBalancer (Dart puro, testeado)
  services/                  AuthService (Google), PushService (FCM), ShareService (imagen)
  ui/                        pantallas: auth, shell, matches, stats, profile, admin
functions/index.js           Cloud Functions (push + bootstrap de admin)
firestore.rules              reglas de seguridad
test/                        tests de la lógica de negocio
```

## Ideas para después

- Marcador del partido y récord ganados/perdidos por jugador (los equipos ya se guardan).
- Control de pagos de la cancha.
- Varios grupos en la misma app.
- Autogoles, vallas invictas y tarjetas.
