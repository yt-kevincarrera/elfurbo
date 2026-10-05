# Diseño de El Furbo: la pizarra táctica

La app es la **pizarra del vestidor**: verde-negra, con tiza, la jornada
dibujada como una cancha y los jugadores como fichas. El texto habla cubano
(ver `docs/tono.md`).

- El tema vive en `lib/core/theme.dart`.
- Las piezas de la pizarra, en `lib/ui/widgets/chalk.dart`.

## Color: tizas sobre pizarra

| Uso | Tiza |
|---|---|
| Texto | Blanca (`Chalk.white`; lo secundario, `Chalk.dim`) |
| Lo importante: botón principal, lo seleccionado, "los que van" | Amarilla (`Chalk.yellow`) |
| Títulos de sección, lo secundario, confirmado | Verde (`Chalk.green`) |
| Rechazado, errores, avisos | Rosa (`Chalk.pink`) |
| Lo que se celebra: MVP, el primero de la tabla, logros | Naranja (`Chalk.orange`) |
| Más fichas | Azul (`Chalk.blue`) |

- Fondo: `Chalk.board`, con capas `boardRaised` / `boardHigh` para diálogos y hojas.
- Encima de toda la app va `ChalkDust`: polvo y borrones muy tenues.
- La app va **siempre en pizarra**: no hay modo claro.
- En las pantallas nada de colores sueltos: siempre las tizas o los roles del esquema.

## Letras

- **Marker** (Permanent Marker): títulos de pantalla y de sección, el
  "cuándo" de la jornada, números grandes (marcadores, puestos).
- **Kalam**: todo el texto, a mano.
- **Mono** (JetBrains Mono, `AppTheme.mono()`): datos, como fechas
  ("MIÉ 7 · 10:00"), contadores, etiquetas de la barra inferior y chips de estado.
- Las fuentes van **dentro de la app** (`assets/fonts`, con sus licencias):
  Google Fonts no carga en Cuba.

## Trazos

- **`ChalkBorder`**: el borde de todo.
  - Doble pasada (el grano de la tiza) en tarjetas, diálogos y menús.
  - **Discontinuo** en botones secundarios, segmentados, chips y estados vacíos.
- **Listas**:
  - Filas sin recuadro separadas por una raya discontinua (`GroupedTile`, `GroupedSection`).
  - Tu fila va resaltada con un toque de amarillo.
- **Jugadores** (`PlayerAvatar` → `ChalkToken`):
  - Aro de tiza con iniciales; el mismo jugador, el mismo color.
  - Ficha llena: "los que van".
  - Discontinua: "quizás" o "sin cuenta".
- **La cancha** (`ChalkPitch`, `ChalkArrow`): la próxima jornada se dibuja
  con los que van en formación en nuestro campo, los "quizás" enfrente y una
  flecha táctica.
- **Podio**: un círculo de tiza alrededor del puesto, el primero en naranja.

## Movimiento y carga

- Cargas con `AppLoading` / `LoadingView` (el indicador que cambia de forma, en tiza amarilla).
- Progreso con `WavyProgressBar`.
- Tarjetas que se tocan, dentro de `Pressable` (rebote).
- Animaciones de entrada que terminan; en bucle, solo los indicadores de carga.

## Ícono

`tool/icon_test.dart` lo dibuja: un balón a tiza (parches amarillos, costuras blancas) con rayas de velocidad verdes sobre la pizarra. Se regenera con:

```bash
flutter test tool/icon_test.dart && dart run flutter_launcher_icons
```

## Pantallas

- La acción principal queda a la vista (botón amarillo, alto 48–56).
- Las secundarias van discontinuas o en un menú `⋯`.
- Lo que el servidor rechazaría no se enseña (ver los permisos en `lib/data/providers.dart`).
