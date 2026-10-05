# Diseño de El Furbo

La app va en la línea de **Material 3 Expressive**: seria y cuidada en lo visual,
aunque el texto hable cubano (ver `docs/tono.md`). El tema vive en
`lib/core/theme.dart` y las piezas propias en `lib/ui/widgets/expressive.dart`.

## Color

- Toda la paleta sale de `AppTheme.seed` (verde terreno), con variante tonal.
  Cambiar ese valor recolorea la app entera.
- El **dorado** (`tertiary`, `scheme.mvpGold`) es solo para lo que se celebra:
  MVP, el primero de la tabla, logros, trofeos.
- Nada de colores sueltos en las pantallas. Se usan roles del esquema
  (`primaryContainer`, `secondaryContainer`, `surfaceContainer*`…).
  Los estados de reportes salen de `StatusColors`.
- Superficies por capas en vez de bordes: las tarjetas no llevan contorno.

## Forma

- Tarjetas con esquinas de 24. Diálogos y hojas inferiores con 28.
- Botones en píldora que se aprietan a esquinas de 12 al pulsar (lo hace el tema).
- **Listas agrupadas**: filas tonales seguidas, con esquinas grandes arriba y
  abajo del grupo y pequeñas entre filas.
  - `GroupedTile` para filas propias.
  - `GroupedSection` para envolver `ListTile`s.
- **Formas de Material** (`material_new_shapes`):
  - Avatares (`PlayerAvatar`): la misma forma y el mismo color para el mismo jugador.
  - Servidor y podio.
  - Fondos de estados vacíos (`ShapeBadge`).
  - Siempre las formas de `AppShapes` o `MaterialShapes`, nunca dibujadas a mano.

## Tipografía

- Títulos con más peso (escala "enfatizada" del tema).
- Los números importantes (goles, puestos, fechas) van grandes y en negrita, como un marcador.
- Las secciones usan `SectionTitle` (sin mayúsculas).

## Movimiento y carga

- **Cargas**:
  - `AppLoading`: el indicador que cambia de forma.
  - `LoadingView`: para pantalla completa.
  - Nunca `CircularProgressIndicator`.
- **Progreso o sincronización**: `WavyProgressBar` (ondulada).
- **Tarjetas que se tocan**: van dentro de `Pressable` (se encogen y vuelven con rebote).
- **Animaciones**:
  - De entrada y que terminen.
  - Nada en bucle infinito salvo los indicadores de carga.
  - Si no, `pumpAndSettle` no termina en los tests y además gasta batería.

## Pantallas

- La acción principal queda a la vista (`FilledButton`, alto 48–56).
- Las secundarias van en un menú `⋯` de la propia fila o tarjeta.
- Lo que el servidor rechazaría no se enseña (ver los providers de permisos en `lib/data/providers.dart`).
