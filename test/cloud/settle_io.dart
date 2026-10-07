import 'dart:io';

import 'package:elfurbo/ui/widgets/expressive.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lo que gira mientras la app espera al disco o a la red.
final _loading = find.byWidgetPredicate(
  (w) => w is AppLoading || w is WavyProgressBar,
);

/// Como pumpAndSettle, pero dejando correr la E/S real (disco, red falsa): repinta
/// hasta que no queda nada cargando ni animándose y, si se pasa [until], hasta
/// que aparece (lo que llega sin indicador, como un diálogo tras leer el disco).
/// pumpAndSettle solo no vale: con el reloj falso la lectura del disco no avanza
/// y el indicador gira para siempre. Esperar un tiempo fijo tampoco: con toda la
/// suite a la vez (en Windows) a veces no alcanza y el test cae de vez en cuando.
Future<void> settleIo(
  WidgetTester tester, {
  Finder? until,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final clock = Stopwatch()..start();
  // Unas vueltas seguidas en calma: entre una carga y la siguiente (la sesión,
  // después el servidor) puede pasar un fotograma sin indicador.
  var calm = 0;
  while (calm < 3) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    final done =
        !tester.binding.hasScheduledFrame &&
        _loading.evaluate().isEmpty &&
        (until == null || until.evaluate().isNotEmpty);
    calm = done ? calm + 1 : 0;
    if (!done && clock.elapsed > timeout) {
      fail(
        'Tras ${timeout.inSeconds} s sigue cargando '
        '(${_loading.evaluate().map((e) => e.widget).toList()})'
        '${until == null ? '' : ' o no aparece lo esperado ($until)'}',
      );
    }
  }
}

/// Carpeta de datos para un test. No se borra al terminar: el sync de fondo
/// puede seguir leyéndola, y borrarla a la vez hace fallar esa lectura ("Access
/// is denied" en Windows) y cae el test después de haber pasado. Tampoco se
/// puede esperar a que el sync acabe: el disco va en cola y puede quedar detrás
/// de una lectura que empezó con el reloj falso, que ya no avanza. Las de
/// pasadas anteriores (de hace más de una hora) se borran aquí.
Future<Directory> dataDir(String prefix) async {
  if (_purged.add(prefix)) await _purge(prefix);
  return Directory.systemTemp.createTemp(prefix);
}

final _purged = <String>{};

Future<void> _purge(String prefix) async {
  final old = DateTime.now().subtract(const Duration(hours: 1));
  // Solo las que hizo createTemp (el prefijo y su sufijo), nada más con ese nombre.
  final ours = RegExp('^${RegExp.escape(prefix)}[0-9a-f]+\$');
  await for (final e in Directory.systemTemp.list()) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is! Directory || !ours.hasMatch(name)) continue;
    try {
      if ((await e.stat()).modified.isBefore(old)) {
        await e.delete(recursive: true);
      }
    } on FileSystemException {
      // Otra pasada la está usando: ya caerá en la siguiente.
    }
  }
}
