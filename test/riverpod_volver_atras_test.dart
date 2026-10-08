import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lo que cambia la pantalla de arriba.
class _Goles extends Notifier<int> {
  @override
  int build() => 0;

  void meter() => state++;
}

final _golesProvider = NotifierProvider<_Goles, int>(_Goles.new);

/// Dos derivados encadenados, como la tabla de un torneo (partidos → tabla →
/// pantalla): con uno solo no se reproduce.
final _totalProvider = Provider((ref) => ref.watch(_golesProvider));
final _marcadorProvider = Provider(
  (ref) => 'Goles: ${ref.watch(_totalProvider)}',
);

class _Abajo extends ConsumerWidget {
  const _Abajo();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Column(
      children: [
        Text(ref.watch(_marcadorProvider)),
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const _Arriba())),
          child: const Text('Abrir'),
        ),
      ],
    ),
  );
}

class _Arriba extends ConsumerWidget {
  const _Arriba();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: TextButton(
      onPressed: () => ref.read(_golesProvider.notifier).meter(),
      child: const Text('Gol'),
    ),
  );
}

void main() {
  // Riverpod pausa lo que mira una ruta tapada y lo reanuda en mitad del build
  // de la transición al volver. Con riverpod 3.3.2 tal cual, eso pedía un
  // refresco con setState durante el build y saltaba la aserción de Flutter
  // (ver third_party/riverpod/LEEME.md). Si este test falla tras subir
  // riverpod, el arreglo no vino con la versión nueva.
  testWidgets(
    'volver a una pantalla cuyo provider cambió mientras estaba tapada',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: _Abajo())),
      );
      expect(find.text('Goles: 0'), findsOneWidget);

      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gol'));
      await tester.pump();

      Navigator.of(tester.element(find.text('Gol'))).pop();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Goles: 1'), findsOneWidget);
    },
  );
}
