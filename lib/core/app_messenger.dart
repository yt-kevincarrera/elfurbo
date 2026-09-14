import 'dart:async';

import 'package:flutter/material.dart';

/// Acceso global al ScaffoldMessenger para avisar resultados de escrituras que
/// se hacen "en segundo plano" (fire-and-forget, así funcionan offline).
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void showMessage(String text) {
  scaffoldMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

void showError(Object error) {
  final text = error.toString().replaceFirst('Exception: ', '');
  scaffoldMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.red.shade700,
      ),
    );
}

/// Dispara una escritura sin esperar a que el servidor la confirme.
///
/// Con la persistencia offline de Firestore, `await` de una escritura no
/// termina hasta tener red; la UI igual se actualiza al instante porque los
/// listeners reciben el cambio local. Si el servidor la rechaza (reglas), se
/// muestra el error cuando llegue.
void fireAndForget(Future<void> future, {String? success}) {
  unawaited(
    future
        .then((_) {
          if (success != null) showMessage(success);
        })
        .catchError((Object e) {
          showError(e);
        }),
  );
}

/// Navigator raíz de la app, para abrir pantallas desde fuera del árbol
/// (por ejemplo al tocar una notificación).
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Pestaña del shell que alguien pidió mostrar (índice), o null. El shell la
/// consume y la vuelve a null.
final requestedHomeTab = ValueNotifier<int?>(null);
