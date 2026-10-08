# riverpod 3.3.2 con un arreglo de 3.4.1

Copia de `lib/` de [riverpod 3.3.2](https://pub.dev/packages/riverpod/versions/3.3.2)
(licencia en `LICENSE`), usada desde el `pubspec.yaml` de la app con
`dependency_overrides`. Solo cambia `lib/src/core/element.dart`, en los dos sitios
marcados con `ELFURBO`.

## Por qué

Riverpod 3 pausa lo que escucha un `Consumer` cuando su ruta no se ve
(`TickerMode` en falso) y lo reanuda al volver. Al hacer `pop` hasta una pantalla
cuyos providers cambiaron mientras estaba tapada (poner un resultado en un partido
del torneo, decir «Voy» en el detalle de una jornada…), la reanudación ocurre en
mitad del build de la transición: el provider se recalcula, avisa a los que lo
miran, y uno de ellos pide un refresco al `UncontrolledProviderScope` con
`setState`. En depuración salta la aserción «setState() or markNeedsBuild() called
during build»; en release no pasa nada, pero tapa cualquier otro error en los
tests y en el móvil de desarrollo.

Riverpod lo arregló en 3.4.1 («Fix markNeedsBuild exception when flushing a
provider inside Widget lifecycle»): `invalidateSelf` ya no pide refresco si el
provider se está recalculando en ese momento (se recalcula enseguida) ni si está
pausado (se recalcula al reanudarse). Es lo único que se trae aquí, copiado tal
cual de 3.4.3.

## Cuándo quitarlo

riverpod 3.4.1 y siguientes piden Dart 3.12 (Flutter 3.44 o más); el proyecto
está en Flutter 3.41.8. Al subir Flutter: borrar esta carpeta y el
`dependency_overrides` del `pubspec.yaml`, subir `flutter_riverpod` a 3.4.1 o
más, y los tests de volver atrás tienen que seguir pasando:
`test/riverpod_volver_atras_test.dart` (el caso mínimo), el de poner un resultado
en `test/cloud/tournament_fixtures_test.dart` y el de decir «Voy» en
`test/cloud/shell_test.dart`.
