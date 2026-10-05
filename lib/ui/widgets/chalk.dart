import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

/// La pizarra táctica: colores de tiza, trazos, polvo y la cancha.
/// Ver `docs/diseno.md`.
abstract final class Chalk {
  /// La pizarra (fondo) y sus capas, de más hondo a más alto.
  static const boardDeep = Color(0xFF151F1A);
  static const board = Color(0xFF1E2A24);
  static const boardRaised = Color(0xFF24332B);
  static const boardHigh = Color(0xFF2B3B32);
  static const boardHighest = Color(0xFF33453B);

  /// Tizas.
  static const white = Color(0xFFEDEFE6);
  static const dim = Color(0xFFB4C2AF);
  static const yellow = Color(0xFFF5E663);
  static const green = Color(0xFF9FD4A8);
  static const pink = Color(0xFFF4A3B4);
  static const blue = Color(0xFF9CC8F2);
  static const orange = Color(0xFFF6B26B);

  /// Las líneas de la cancha y los bordes.
  static Color line([double opacity = .7]) => white.withValues(alpha: opacity);

  /// Colores para las fichas de jugador (el mismo jugador, el mismo color).
  static const tokens = [yellow, green, pink, blue, orange];
}

/// Borde de tiza: un trazo con doble pasada (como la tiza sobre la pizarra) o
/// discontinuo. Sirve de forma para tarjetas, botones, chips y diálogos.
class ChalkBorder extends OutlinedBorder {
  const ChalkBorder({super.side, this.radius = 14, this.dashed = false});

  final double radius;
  final bool dashed;

  RRect _rrect(Rect rect, [double inset = 0]) {
    final r = rect.deflate(inset);
    return RRect.fromRectAndRadius(
      r,
      Radius.circular(math.min(radius, r.shortestSide / 2)),
    );
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect, side.width));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    final path = Path()..addRRect(_rrect(rect, side.width / 2));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = side.width
      ..strokeCap = StrokeCap.round
      ..color = side.color;
    if (dashed) {
      for (final m in path.computeMetrics()) {
        _dash(canvas, m, paint, dash: 7, gap: 5);
      }
      return;
    }
    canvas.drawPath(path, paint);
    // Segunda pasada, un pelo corrida y más tenue: el grano de la tiza.
    canvas.drawPath(
      path.shift(const Offset(.7, -.5)),
      paint
        ..color = side.color.withValues(alpha: side.color.a * .35)
        ..strokeWidth = side.width * .8,
    );
  }

  static void _dash(
    Canvas canvas,
    PathMetric m,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    var d = 0.0;
    while (d < m.length) {
      canvas.drawPath(m.extractPath(d, math.min(d + dash, m.length)), paint);
      d += dash + gap;
    }
  }

  @override
  ChalkBorder copyWith({BorderSide? side, double? radius, bool? dashed}) =>
      ChalkBorder(
        side: side ?? this.side,
        radius: radius ?? this.radius,
        dashed: dashed ?? this.dashed,
      );

  @override
  ShapeBorder scale(double t) =>
      ChalkBorder(side: side.scale(t), radius: radius * t, dashed: dashed);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is ChalkBorder) {
      return ChalkBorder(
        side: BorderSide.lerp(a.side, side, t),
        radius: a.radius + (radius - a.radius) * t,
        dashed: t < .5 ? a.dashed : dashed,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is ChalkBorder) {
      return ChalkBorder(
        side: BorderSide.lerp(side, b.side, t),
        radius: radius + (b.radius - radius) * t,
        dashed: t < .5 ? dashed : b.dashed,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  bool operator ==(Object other) =>
      other is ChalkBorder &&
      other.side == side &&
      other.radius == radius &&
      other.dashed == dashed;

  @override
  int get hashCode => Object.hash(side, radius, dashed);
}

/// Polvo de tiza y borrones encima de toda la app: muy tenue, no estorba al
/// leer ni a los toques. Se pinta una vez (siempre igual).
class ChalkDust extends StatelessWidget {
  const ChalkDust({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        const IgnorePointer(
          child: RepaintBoundary(child: CustomPaint(painter: _DustPainter())),
        ),
      ],
    );
  }
}

class _DustPainter extends CustomPainter {
  const _DustPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    final p = Paint()..strokeCap = StrokeCap.round;
    // Borrones grandes de borrador.
    for (var i = 0; i < 9; i++) {
      final c = Offset(
        rnd.nextDouble() * size.width,
        rnd.nextDouble() * size.height,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: c,
          width: 140 + rnd.nextDouble() * 220,
          height: 40 + rnd.nextDouble() * 70,
        ),
        Paint()
          ..color = Chalk.white.withValues(alpha: .018 + rnd.nextDouble() * .02)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26),
      );
    }
    // Rayitas de polvo, casi horizontales.
    for (var i = 0; i < 260; i++) {
      final x = rnd.nextDouble() * size.width;
      final y = rnd.nextDouble() * size.height;
      final len = 4 + rnd.nextDouble() * 22;
      final a = (rnd.nextDouble() - .5) * .5;
      p
        ..strokeWidth = .6 + rnd.nextDouble() * 1.6
        ..color = Chalk.white.withValues(alpha: .02 + rnd.nextDouble() * .035);
      canvas.drawLine(
        Offset(x, y),
        Offset(x + len * math.cos(a), y + len * math.sin(a)),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_DustPainter old) => false;
}

/// Ficha de jugador en la pizarra: un círculo de tiza con sus iniciales.
/// [filled]: ficha llena (los que van); si no, solo el aro (quizás, rivales).
class ChalkToken extends StatelessWidget {
  const ChalkToken({
    super.key,
    required this.label,
    required this.color,
    this.size = 32,
    this.filled = false,
    this.dashed = false,
  });

  final String label;
  final Color color;
  final double size;
  final bool filled;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _TokenPainter(color: color, filled: filled, dashed: dashed),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontFamily: 'Mono',
              fontVariations: const [FontVariation('wght', 800)],
              fontSize: size * (label.length > 2 ? .26 : .34),
              color: filled ? Chalk.board : color,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _TokenPainter extends CustomPainter {
  const _TokenPainter({
    required this.color,
    required this.filled,
    required this.dashed,
  });

  final Color color;
  final bool filled;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final border = ChalkBorder(
      side: BorderSide(color: color, width: size.width * .07),
      radius: size.width,
      dashed: dashed,
    );
    if (filled) {
      canvas.drawOval(rect.deflate(size.width * .04), Paint()..color = color);
      return;
    }
    canvas.drawOval(rect.deflate(2), Paint()..color = Chalk.board);
    border.paint(canvas, rect);
  }

  @override
  bool shouldRepaint(_TokenPainter old) =>
      old.color != color || old.filled != filled || old.dashed != dashed;
}

/// Media cancha o cancha entera a tiza, con espacio para poner fichas encima.
class ChalkPitch extends StatelessWidget {
  const ChalkPitch({super.key, this.children = const []});

  /// Lo que va encima (fichas posicionadas, notas).
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _PitchPainter(),
      child: Stack(children: children),
    );
  }
}

class _PitchPainter extends CustomPainter {
  const _PitchPainter();

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = Chalk.line(.55);
    final outer = RRect.fromRectAndRadius(
      (Offset.zero & s).deflate(1.5),
      const Radius.circular(6),
    );
    canvas.drawRRect(outer, p..color = Chalk.line(.8));
    p.color = Chalk.line(.55);
    canvas.drawLine(
      Offset(s.width / 2, 2),
      Offset(s.width / 2, s.height - 2),
      p,
    );
    final r = s.height * .16;
    canvas.drawCircle(Offset(s.width / 2, s.height / 2), r, p);
    canvas.drawCircle(
      Offset(s.width / 2, s.height / 2),
      2.5,
      Paint()..color = Chalk.line(.6),
    );
    final boxW = s.width * .15;
    final boxH = s.height * .46;
    final top = (s.height - boxH) / 2;
    canvas.drawRect(Rect.fromLTWH(1.5, top, boxW, boxH), p);
    canvas.drawRect(Rect.fromLTWH(s.width - boxW - 1.5, top, boxW, boxH), p);
    final smallH = boxH * .45;
    final smallTop = (s.height - smallH) / 2;
    canvas.drawRect(Rect.fromLTWH(1.5, smallTop, boxW * .4, smallH), p);
    canvas.drawRect(
      Rect.fromLTWH(s.width - boxW * .4 - 1.5, smallTop, boxW * .4, smallH),
      p,
    );
  }

  @override
  bool shouldRepaint(_PitchPainter old) => false;
}

/// Una flecha de tiza discontinua (curva) de [from] a [to], para la cancha.
class ChalkArrow extends StatelessWidget {
  const ChalkArrow({super.key, required this.from, required this.to});

  final Offset from;
  final Offset to;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _ArrowPainter(from, to), size: Size.infinite);
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter(this.from, this.to);

  final Offset from;
  final Offset to;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = Offset((from.dx + to.dx) / 2, math.min(from.dy, to.dy) - 34);
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(mid.dx, mid.dy, to.dx, to.dy);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..color = Chalk.yellow.withValues(alpha: .9);
    for (final m in path.computeMetrics()) {
      ChalkBorder._dash(canvas, m, p, dash: 6, gap: 5);
      // Punta de flecha.
      final t = m.getTangentForOffset(m.length);
      if (t == null) continue;
      final a = t.angle;
      for (final d in [2.6, -2.6]) {
        canvas.drawLine(
          t.position,
          t.position - Offset.fromDirection(-a + d / 6 * math.pi / 2.4, 9),
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.from != from || old.to != to;
}
