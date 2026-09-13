# El Furbo ⚽

App Android para el grupo de amigos que juega al fútbol: cada uno carga sus goles y
asistencias después del partido, los compañeros (o el admin) confirman que es verdad, y
las estadísticas se acumulan partido a partido. Funciona **sin internet** y sincroniza sola
cuando vuelve la conexión.

## Qué hace

| Feature | Cómo funciona |
| --- | --- |
| **Partidos** | El admin crea partidos con fecha, hora y cancha. Se pueden editar, cancelar o eliminar. |
| **Asistencia** | Antes del partido cada uno marca *Voy / Quizás / No voy*. Después del partido, *Jugué*. |
| **Reportes** | Cada jugador carga sus goles y asistencias (y un comentario opcional). |
| **Confirmación** | Un reporte cuenta cuando lo confirman **2 compañeros que jugaron ese día** o **el admin**. El admin también puede rechazarlo. Si el autor edita el reporte, vuelve a pendiente. |
| **MVP** | Los que jugaron votan al mejor del partido. Si hay empate, todos los empatados suman MVP. |
| **Tabla** | Ranking por goles, asistencias, MVP y G+A. Filtrable por temporada o histórico total. |
| **Perfil** | Stats del jugador, posición en cada ranking, curva de evolución partido a partido, historial. |
| **Logros y rachas** | Hat-trick, Póker, Goleador (10/50/100), Fiel (5/10/25 seguidos), MVP, Imparable, etc. Se recalculan siempre a partir de los datos. |
| **Equipos parejos** | Con los que marcaron que van, la app propone dos equipos balanceados por rendimiento histórico. "Mezclar de nuevo" da otra combinación igual de pareja. El admin los guarda. |
| **Compartir** | Tarjeta con goleadores, MVP y top 3 de la temporada, lista para mandar al grupo de WhatsApp. |
| **Temporadas** | El admin cierra el año y abre una temporada nueva. La tabla arranca de cero; el histórico se conserva. |
| **Notificaciones** | Hoy hay partido → marcá asistencia. Alguien reportó → confirmalo. Te confirmaron. Nuevo jugador esperando aprobación. |
| **Offline** | Firestore guarda todo en el teléfono. Podés cargar goles en la cancha sin señal y se sube después. Una barra arriba avisa si estás offline o con cambios sin subir. |
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

1. Entrá a [console.firebase.google.com](https://console.firebase.google.com) y creá un proyecto (por ejemplo `elfurbo`).
2. **Agregar app → Android**. Nombre del paquete: `app.elfurbo` (tiene que coincidir con `applicationId` en `android/app/build.gradle.kts`).
3. Cargá la **huella SHA-1** de tu clave de firma. Para la clave de debug:

   ```bash
   keytool -list -v -alias androiddebugkey -keystore ~/.android/debug.keystore -storepass android -keypass android
   ```

   Sin el SHA-1 correcto, el login con Google falla. Cuando firmes el APK de release con otra clave, agregá también ese SHA-1.
4. Descargá **`google-services.json`** y guardalo en `android/app/google-services.json` (está en `.gitignore`; hay una plantilla en `google-services.json.example`).

### 3. Authentication

Firebase Console → **Authentication → Sign-in method → Google → Habilitar**. Poné un correo de soporte y guardá.

### 4. Firestore

1. **Firestore Database → Crear base de datos**, modo producción. Elegí la región más cercana (por ejemplo `southamerica-east1`).
2. Vinculá el repo al proyecto y subí las reglas de seguridad:

   ```bash
   cp .firebaserc.example .firebaserc      # editá el project id
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

Antes de desplegar, revisá en `functions/index.js`:

- `REGION`: debe coincidir con la región de tu Firestore (o `us-central1` si elegiste una multi-región).
- `TIME_ZONE`: zona horaria del grupo para los recordatorios de las 09:00 y las 22:00.

> Si no querés usar Functions, la app funciona igual. Lo único que perdés son las notificaciones, y al primer admin lo tenés que marcar a mano (ver abajo).

### 6. Compilar e instalar

```bash
flutter pub get
flutter run                  # con un teléfono conectado o un emulador
flutter build apk --release  # genera build/app/outputs/flutter-apk/app-release.apk
```

Para repartir el APK a los amigos, firmalo con una clave propia siguiendo la
[guía oficial](https://docs.flutter.dev/deployment/android#signing-the-app) y acordate de
cargar el SHA-1 de esa clave en Firebase.

### 7. Primer uso

1. Entrá con tu Google. Si las Functions están desplegadas, **el primer usuario queda como admin activo automáticamente**.
   Si no, en Firebase Console → Firestore → colección `users` → tu documento, poné `role: "admin"` y `status: "active"`.
2. Cada amigo entra con su Google y te aparece en la pestaña **Admin → Pendientes**. Aprobalo con un toque.
3. Creá el primer partido. Se genera sola una temporada (`Temporada 2026`); podés renombrarla en Admin.

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
