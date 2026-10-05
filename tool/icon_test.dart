// Genera el ícono de la app (la pizarra) en assets/icon/:
//
//   flutter test tool/icon_test.dart
//   dart run flutter_launcher_icons
import 'dart:io';
import 'dart:ui' as ui;

import 'package:elfurbo/ui/widgets/chalk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = 1024.0;

/// La ficha amarilla con la F a rotulador, la flecha y un trozo de cancha.
class _Icon extends StatelessWidget {
  const _Icon({required this.background, required this.mono, this.scale = 1});

  final bool background;
  final bool mono;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final ink = mono ? Colors.white : Chalk.yellow;
    final lines = mono ? Colors.white : Chalk.white.withValues(alpha: .35);
    return SizedBox.square(
      dimension: _size,
      child: ColoredBox(
        color: background ? Chalk.board : Colors.transparent,
        child: Transform.scale(
          scale: scale,
          child: CustomPaint(
            painter: _LinesPainter(lines, mono: mono),
            child: Center(
              child: SizedBox.square(
                dimension: 560,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: mono ? Colors.white : ink,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Transform.translate(
                      offset: const Offset(-6, 18),
                      child: Text(
                        'F',
                        style: TextStyle(
                          fontFamily: 'Marker',
                          fontSize: 400,
                          height: 1,
                          color: mono ? null : Chalk.board,
                          foreground: mono
                              ? (Paint()..blendMode = BlendMode.clear)
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La línea de medio campo y el círculo central detrás, y una flecha de tiza.
class _LinesPainter extends CustomPainter {
  _LinesPainter(this.color, {required this.mono});

  final Color color;
  final bool mono;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..strokeCap = StrokeCap.round
      ..color = color;
    if (!mono) {
      canvas.drawCircle(s.center(Offset.zero), 400, p);
      canvas.drawLine(Offset(s.width / 2, 0), Offset(s.width / 2, s.height), p);
    }
    // Flecha táctica entrando a la ficha.
    final arrow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 30
      ..strokeCap = StrokeCap.round
      ..color = mono ? Colors.white : Chalk.green;
    final path = Path()
      ..moveTo(150, 860)
      ..quadraticBezierTo(170, 700, 300, 640);
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 70) {
        canvas.drawPath(m.extractPath(d, d + 40), arrow);
      }
    }
    canvas.drawLine(const Offset(300, 640), const Offset(232, 618), arrow);
    canvas.drawLine(const Offset(300, 640), const Offset(262, 700), arrow);
  }

  @override
  bool shouldRepaint(_LinesPainter old) => false;
}

void main() {
  setUpAll(() async {
    final marker = FontLoader('Marker')
      ..addFont(
        Future.value(
          ByteData.view(
            File(
              'assets/fonts/PermanentMarker-Regular.ttf',
            ).readAsBytesSync().buffer,
          ),
        ),
      );
    await marker.load();
  });

  for (final (name, widget) in [
    ('icon', const _Icon(background: true, mono: false)),
    // Adaptativo: solo lo de delante, dentro de la zona segura (66 %).
    (
      'icon_foreground',
      const _Icon(background: false, mono: false, scale: .62),
    ),
    ('icon_monochrome', const _Icon(background: false, mono: true, scale: .62)),
  ]) {
    testWidgets(name, (tester) async {
      tester.view.physicalSize = const Size(_size, _size);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(key: key, child: widget),
          ),
        ),
      );
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          'assets/icon/$name.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    });
  }
}
