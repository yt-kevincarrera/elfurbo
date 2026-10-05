// Genera el ícono de la app (un balón a tiza sobre la pizarra) en assets/icon/:
//
//   flutter test tool/icon_test.dart
//   dart run flutter_launcher_icons
//
// También deja una vista previa (grande y pequeño) en build/icon_preview.png.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:elfurbo/ui/widgets/chalk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = 1024.0;

/// Un trazo de tiza: doble pasada y grano de pizarra asomando.
void _chalk(Canvas c, Path path, Color color, double width, {int seed = 1}) {
  c.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color,
  );
  c.drawPath(
    path.shift(Offset(width * .12, -width * .1)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * .55
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: .45),
  );
  final rnd = math.Random(seed);
  final grain = Paint()..color = Chalk.board.withValues(alpha: .4);
  for (final m in path.computeMetrics()) {
    for (var d = 0.0; d < m.length; d += 8) {
      final t = m.getTangentForOffset(d);
      if (t == null || rnd.nextDouble() > .3) continue;
      c.drawCircle(
        t.position +
            Offset(
              (rnd.nextDouble() - .5) * width * .8,
              (rnd.nextDouble() - .5) * width * .8,
            ),
        width * (.05 + rnd.nextDouble() * .09),
        grain,
      );
    }
  }
}

Path _polygon(Offset center, double radius, double rotation, [int sides = 5]) {
  final p = Path();
  for (var i = 0; i < sides; i++) {
    final pt =
        center +
        Offset.fromDirection(rotation + i * 2 * math.pi / sides, radius);
    i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
  }
  return p..close();
}

/// El balón (con sus rayas de velocidad) en un cuadrado de [s].
void drawBall(Canvas c, Size s, {required bool mono}) {
  final white = mono ? Colors.white : Chalk.white;
  final patch = mono ? Colors.white : Chalk.yellow;
  final speed = mono ? Colors.white : Chalk.green;
  final k = s.width / _size;
  final center = Offset(590 * k, 512 * k);
  final r = 300 * k;
  const up = -math.pi / 2;

  // Parches: el pentágono del centro y cinco más contra el borde.
  final inner = _polygon(center, r * .33, up);
  c.drawPath(inner, Paint()..color = patch);
  c.save();
  c.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
  for (var i = 0; i < 5; i++) {
    final a = up + i * 2 * math.pi / 5;
    c.drawPath(
      _polygon(center + Offset.fromDirection(a, r * .93), r * .3, a + math.pi),
      Paint()..color = patch,
    );
  }
  c.restore();

  // Costuras, como en un balón de verdad: del pentágono central a la punta
  // de cada parche del borde; entre parches vecinos, de esquina a esquina, y
  // de ahí una costura hasta el borde.
  final seams = Path();
  Offset patchCenter(int i) =>
      center + Offset.fromDirection(up + i * 2 * math.pi / 5, r * .93);
  List<Offset> patchCorners(int i) {
    final a = up + i * 2 * math.pi / 5;
    return [
      for (var j = 0; j < 5; j++)
        patchCenter(i) +
            Offset.fromDirection(a + math.pi + j * 2 * math.pi / 5, r * .3),
    ];
  }

  Offset nearest(List<Offset> pts, Offset to) =>
      pts.reduce((p, q) => (p - to).distance <= (q - to).distance ? p : q);
  for (var i = 0; i < 5; i++) {
    final a = up + i * 2 * math.pi / 5;
    final from = center + Offset.fromDirection(a, r * .33);
    final tip = center + Offset.fromDirection(a, r * .63);
    seams
      ..moveTo(from.dx, from.dy)
      ..lineTo(tip.dx, tip.dy);
    final j = (i + 1) % 5;
    final v1 = nearest(patchCorners(i), patchCenter(j));
    final v2 = nearest(patchCorners(j), patchCenter(i));
    final mid = Offset((v1.dx + v2.dx) / 2, (v1.dy + v2.dy) / 2);
    final out = center + (mid - center) / (mid - center).distance * r * 1.1;
    seams
      ..moveTo(v1.dx, v1.dy)
      ..lineTo(v2.dx, v2.dy)
      ..moveTo(mid.dx, mid.dy)
      ..lineTo(out.dx, out.dy);
  }
  c.save();
  c.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
  _chalk(c, seams, white, 20 * k, seed: 2);
  c.restore();
  _chalk(c, inner, patch, 18 * k, seed: 3);

  // El contorno, encima de todo.
  _chalk(
    c,
    Path()..addOval(Rect.fromCircle(center: center, radius: r)),
    white,
    36 * k,
    seed: 4,
  );

  // Rayas de velocidad.
  for (final (i, (y, x0, len)) in [
    (390.0, 110.0, 120.0),
    (512.0, 70.0, 150.0),
    (634.0, 110.0, 120.0),
  ].indexed) {
    _chalk(
      c,
      Path()
        ..moveTo(x0 * k, y * k)
        ..lineTo((x0 + len) * k, y * k),
      speed,
      30 * k,
      seed: 10 + i,
    );
  }
}

/// La pizarra de fondo, con borrones de borrador.
void drawBoard(Canvas c, Size s) {
  c.drawRect(Offset.zero & s, Paint()..color = Chalk.board);
  final rnd = math.Random(3);
  for (var i = 0; i < 6; i++) {
    c.drawOval(
      Rect.fromCenter(
        center: Offset(rnd.nextDouble() * s.width, rnd.nextDouble() * s.height),
        width: s.width * .5,
        height: s.height * .16,
      ),
      Paint()
        ..color = Chalk.white.withValues(alpha: .035)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s.width * .06),
    );
  }
}

class _IconPainter extends CustomPainter {
  _IconPainter({required this.background, required this.mono, this.scale = 1});

  final bool background;
  final bool mono;
  final double scale;

  @override
  void paint(Canvas c, Size s) {
    if (background) drawBoard(c, s);
    c.save();
    c.translate(s.width * (1 - scale) / 2, s.height * (1 - scale) / 2);
    drawBall(c, s * scale, mono: mono);
    c.restore();
  }

  @override
  bool shouldRepaint(_IconPainter old) => false;
}

Future<void> _save(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await b.toImage();
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  for (final (name, painter) in [
    ('icon', _IconPainter(background: true, mono: false)),
    // Adaptativo: solo lo de delante, dentro de la zona segura (66 %).
    (
      'icon_foreground',
      _IconPainter(background: false, mono: false, scale: .64),
    ),
    (
      'icon_monochrome',
      _IconPainter(background: false, mono: true, scale: .64),
    ),
  ]) {
    testWidgets(name, (tester) async {
      tester.view.physicalSize = const Size(_size, _size);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: CustomPaint(painter: painter, size: const Size.square(_size)),
        ),
      );
      await _save(tester, key, 'assets/icon/$name.png');
    });
  }

  testWidgets('vista previa: grande y a tamaño de lanzador', (tester) async {
    tester.view.physicalSize = const Size(900, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    Widget icon(double size) => ClipRRect(
      borderRadius: BorderRadius.circular(size * .22),
      child: CustomPaint(
        painter: _IconPainter(background: true, mono: false),
        size: Size.square(size),
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xFF101310),
          child: Row(
            textDirection: TextDirection.ltr,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [icon(440), icon(144), icon(96), icon(48)],
          ),
        ),
      ),
    );
    await _save(tester, key, 'build/icon_preview.png');
  });
}
