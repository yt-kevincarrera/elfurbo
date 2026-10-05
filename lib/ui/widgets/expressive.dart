import 'dart:math' as math;

import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import 'chalk.dart';

// Piezas de Material 3 Expressive que Flutter todavía no trae: el indicador de
// carga que cambia de forma, las formas de Material (de androidx.graphics.shapes),
// la barra de progreso ondulada y la respuesta al pulsar con rebote.

/// Indicador de carga de Material 3 Expressive (formas que se transforman).
/// [contained] lo pone dentro de un círculo tonal, para cargas a pantalla
/// completa o encima de contenido.
class AppLoading extends StatelessWidget {
  const AppLoading({
    super.key,
    this.size = 48,
    this.contained = false,
    this.color,
  });

  final double size;
  final bool contained;

  /// Por defecto, el primario (o el de encima del contenedor).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final indicator = ExpressiveLoadingIndicator(
      color: color ?? (contained ? scheme.onPrimaryContainer : scheme.primary),
      constraints: BoxConstraints.tight(Size.square(size)),
      semanticsLabel: 'Cargando',
    );
    if (!contained) return indicator;
    return Container(
      width: size * 1.5,
      height: size * 1.5,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: indicator,
    );
  }
}

/// Pantalla de espera: el indicador en el centro y, si hay, un texto debajo.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppLoading(size: 56, contained: true),
          if (message != null) ...[
            const SizedBox(height: 20),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Una forma de Material (galleta, sol, flor…) como borde: sirve para
/// `ShapeDecoration`, `Material(shape:)` o `ClipPath`.
class PolygonBorder extends ShapeBorder {
  const PolygonBorder(this.polygon);

  final RoundedPolygon polygon;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    // La forma normalizada vive en [0, 1]: se escala al rectángulo.
    final path = polygon.normalized().toPath();
    final m = Matrix4.identity()
      ..translateByDouble(rect.left, rect.top, 0, 1)
      ..scaleByDouble(rect.width, rect.height, 1, 1);
    return path.transform(m.storage);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Un fondo con forma de Material y algo encima (un ícono, unas iniciales).
class ShapeBadge extends StatelessWidget {
  const ShapeBadge({
    super.key,
    required this.shape,
    required this.color,
    required this.size,
    this.child,
  });

  final RoundedPolygon shape;
  final Color color;
  final double size;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(color: color, shape: PolygonBorder(shape)),
        child: Center(child: child),
      ),
    );
  }
}

/// Barra de progreso ondulada (Material 3 Expressive). Sin [value], la onda
/// avanza sola; con [value], se rellena hasta ahí.
class WavyProgressBar extends StatefulWidget {
  const WavyProgressBar({super.key, this.value, this.height = 10});

  final double? value;
  final double height;

  @override
  State<WavyProgressBar> createState() => _WavyProgressBarState();
}

class _WavyProgressBarState extends State<WavyProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Progreso',
      value: widget.value == null ? null : '${(widget.value! * 100).round()}%',
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            painter: _WavyPainter(
              phase: _c.value,
              value: widget.value,
              color: scheme.primary,
              track: scheme.secondaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

class _WavyPainter extends CustomPainter {
  _WavyPainter({
    required this.phase,
    required this.value,
    required this.color,
    required this.track,
  });

  final double phase;
  final double? value;
  final Color color;
  final Color track;

  static const _stroke = 4.0;
  static const _wavelength = 28.0;
  static const _gap = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final amplitude = (size.height - _stroke) / 2;
    final paint = Paint()
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Indeterminada: un tramo ondulado que recorre la barra de lado a lado.
    final double start;
    final double end;
    if (value == null) {
      final head = Curves.easeInOut.transform(phase);
      final tail = Curves.easeInOut.transform(
        (phase - 0.35).clamp(0, 1) / 0.65,
      );
      start = tail * size.width;
      end = math.max(start + 1, head * size.width);
    } else {
      start = 0;
      end = value!.clamp(0, 1) * size.width;
    }

    final wave = Path();
    for (var x = start; x <= end; x += 1) {
      final y =
          mid +
          amplitude * math.sin((x / _wavelength + phase * 2) * 2 * math.pi);
      x == start ? wave.moveTo(x, y) : wave.lineTo(x, y);
    }
    canvas.drawPath(wave, paint..color = color);

    // La pista: recta, con un hueco antes y después del tramo activo.
    paint.color = track;
    if (start - _gap > _stroke) {
      canvas.drawLine(
        const Offset(_stroke / 2, 0) + Offset(0, mid),
        Offset(start - _gap, mid),
        paint,
      );
    }
    if (end + _gap < size.width - _stroke / 2) {
      canvas.drawLine(
        Offset(end + _gap, mid),
        Offset(size.width - _stroke / 2, mid),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavyPainter old) =>
      old.phase != phase || old.value != value || old.color != color;
}

/// Se encoge un poco al pulsar y vuelve con rebote: para tarjetas y bloques
/// que se pueden tocar. No captura el toque (lo sigue recibiendo el hijo).
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.scale = 0.97});

  final Widget child;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: Duration(milliseconds: _down ? 120 : 380),
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: widget.child,
      ),
    );
  }
}

/// Fila de una lista en la pizarra: sin recuadro, separada de la siguiente
/// por una raya de tiza discontinua. [color] la resalta (por ejemplo, tu fila).
class GroupedTile extends StatelessWidget {
  const GroupedTile({
    super.key,
    required this.index,
    required this.count,
    required this.child,
    this.color,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  });

  final int index;
  final int count;
  final Widget child;
  final Color? color;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final last = index == count - 1;
    return CustomPaint(
      foregroundPainter: last ? null : const _DashedRule(),
      child: Material(
        color: color == null
            ? Colors.transparent
            : Chalk.yellow.withValues(alpha: .09),
        shape: color == null ? null : const ChalkBorder(radius: 12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class _DashedRule extends CustomPainter {
  const _DashedRule();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Chalk.line(.28)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (var x = 6.0; x < size.width - 6; x += 11) {
      canvas.drawLine(
        Offset(x, size.height - .7),
        Offset(math.min(x + 6, size.width - 6), size.height - .7),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedRule old) => false;
}

/// Varias filas (por ejemplo `ListTile`) como una lista de la pizarra.
class GroupedSection extends StatelessWidget {
  const GroupedSection({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          for (final (i, child) in children.indexed)
            CustomPaint(
              foregroundPainter: i == children.length - 1
                  ? null
                  : const _DashedRule(),
              child: child,
            ),
        ],
      ),
    );
  }
}

/// Formas para avatares y fondos decorativos: el mismo id siempre cae en la
/// misma forma.
abstract final class AppShapes {
  static final avatars = [
    MaterialShapes.cookie9Sided,
    MaterialShapes.sunny,
    MaterialShapes.cookie7Sided,
    MaterialShapes.softBurst,
    MaterialShapes.cookie12Sided,
  ];

  /// Hash estable de un id (el de String no está garantizado entre versiones).
  static int hashOf(String id) =>
      id.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x3fffffff);

  static RoundedPolygon forId(String id) =>
      avatars[hashOf(id) % avatars.length];
}
