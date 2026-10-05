import 'package:flutter/material.dart';

import '../ui/widgets/chalk.dart';

/// Tema de la app: la **pizarra táctica** (ver `docs/diseno.md`).
///
/// - Pizarra verde-negra con tizas: blanca para el texto, amarilla para lo
///   importante, verde para lo secundario, rosa para lo rechazado.
/// - Letras: Marker (Permanent Marker) en títulos, Kalam (a mano) en el texto y
///   Mono (JetBrains Mono) en números y datos.
/// - Bordes de tiza (doble pasada o discontinuos) en vez de superficies planas.
///
/// Es un concepto oscuro: la app va siempre en pizarra, también con el teléfono
/// en modo claro.
class AppTheme {
  /// Dorado del ícono (notificaciones).
  static const gold = Color(0xFFE0B84A);

  static ThemeData light() => board();
  static ThemeData dark() => board();

  static const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Chalk.yellow,
    onPrimary: Chalk.board,
    primaryContainer: Chalk.yellow,
    onPrimaryContainer: Chalk.board,
    secondary: Chalk.green,
    onSecondary: Chalk.board,
    secondaryContainer: Color(0xFF34503F),
    onSecondaryContainer: Color(0xFFD9F2DD),
    tertiary: Chalk.orange,
    onTertiary: Chalk.board,
    tertiaryContainer: Color(0xFF55402A),
    onTertiaryContainer: Color(0xFFFFE2C2),
    error: Chalk.pink,
    onError: Chalk.board,
    errorContainer: Color(0xFF5A2E38),
    onErrorContainer: Color(0xFFFFD9E0),
    surface: Chalk.board,
    onSurface: Chalk.white,
    onSurfaceVariant: Chalk.dim,
    surfaceDim: Chalk.boardDeep,
    surfaceBright: Chalk.boardHighest,
    surfaceContainerLowest: Chalk.boardDeep,
    surfaceContainerLow: Chalk.boardRaised,
    surfaceContainer: Chalk.boardRaised,
    surfaceContainerHigh: Chalk.boardHigh,
    surfaceContainerHighest: Chalk.boardHighest,
    outline: Color(0xFF7D8C80),
    outlineVariant: Color(0xFF3E5045),
    inverseSurface: Chalk.white,
    onInverseSurface: Chalk.board,
    inversePrimary: Chalk.board,
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );

  /// Números y datos (fechas, marcadores, contadores).
  static TextStyle mono({
    double size = 13,
    double weight = 600,
    Color? color,
    double spacing = .6,
  }) => TextStyle(
    fontFamily: 'Mono',
    fontSize: size,
    fontVariations: [FontVariation('wght', weight)],
    fontWeight: weight >= 600 ? FontWeight.w700 : FontWeight.w400,
    letterSpacing: spacing,
    color: color,
  );

  static TextTheme _text() {
    const marker = 'Marker';
    const hand = 'Kalam';
    TextStyle m(double size, [double height = 1.1]) => TextStyle(
      fontFamily: marker,
      fontSize: size,
      height: height,
      color: Chalk.white,
    );
    TextStyle h(double size, {bool bold = false, double height = 1.3}) =>
        TextStyle(
          fontFamily: hand,
          fontSize: size,
          height: height,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          color: Chalk.white,
        );
    return TextTheme(
      displayLarge: m(56, 1),
      displayMedium: m(46, 1),
      displaySmall: m(38, 1.05),
      headlineLarge: m(32),
      headlineMedium: m(28),
      headlineSmall: m(24),
      titleLarge: h(22, bold: true, height: 1.2),
      titleMedium: h(18, bold: true, height: 1.25),
      titleSmall: h(16, bold: true),
      bodyLarge: h(17),
      bodyMedium: h(15.5),
      bodySmall: h(13.5).copyWith(color: Chalk.dim),
      labelLarge: h(16, bold: true, height: 1.1),
      labelMedium: h(14, bold: true, height: 1.1),
      labelSmall: h(12.5, bold: true, height: 1.1),
    );
  }

  static ThemeData board() {
    const s = scheme;
    final text = _text();
    final chalkLine = BorderSide(color: Chalk.line(.55), width: 1.6);
    final buttonText = WidgetStatePropertyAll(
      text.labelLarge?.copyWith(fontSize: 18),
    );
    const buttonPad = WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 22),
    );
    const buttonSize = WidgetStatePropertyAll(Size(64, 48));

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: s,
      brightness: Brightness.dark,
      fontFamily: 'Kalam',
    );
    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: Chalk.board,
      canvasColor: Chalk.board,
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Chalk.board,
        foregroundColor: Chalk.white,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.headlineMedium,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white.withValues(alpha: .025),
        clipBehavior: Clip.antiAlias,
        shape: ChalkBorder(side: chalkLine, radius: 16),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(ChalkBorder(radius: 14)),
          textStyle: buttonText,
          padding: buttonPad,
          minimumSize: buttonSize,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            ChalkBorder(side: chalkLine, radius: 14, dashed: true),
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: Chalk.line(.75), width: 2),
          ),
          foregroundColor: const WidgetStatePropertyAll(Chalk.white),
          textStyle: buttonText,
          padding: buttonPad,
          minimumSize: buttonSize,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(Chalk.yellow),
          textStyle: buttonText,
          shape: const WidgetStatePropertyAll(ChalkBorder(radius: 12)),
        ),
      ),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(ChalkBorder(radius: 14)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: Chalk.yellow,
        foregroundColor: Chalk.board,
        elevation: 0,
        highlightElevation: 0,
        shape: const ChalkBorder(radius: 18),
        extendedTextStyle: text.titleMedium?.copyWith(fontSize: 19),
        extendedSizeConstraints: const BoxConstraints.tightFor(height: 58),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            ChalkBorder(side: chalkLine, radius: 12, dashed: true),
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: Chalk.line(.6), width: 1.8),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(0, 46)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          foregroundColor: WidgetStateProperty.resolveWith(
            (st) =>
                st.contains(WidgetState.selected) ? Chalk.board : Chalk.white,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (st) => st.contains(WidgetState.selected)
                ? Chalk.yellow
                : Colors.transparent,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: ChalkBorder(side: chalkLine, radius: 10, dashed: true),
        side: BorderSide(color: Chalk.line(.5), width: 1.4),
        backgroundColor: Colors.transparent,
        labelStyle: text.labelLarge,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: .04),
        labelStyle: text.bodyLarge?.copyWith(color: Chalk.dim),
        hintStyle: text.bodyLarge?.copyWith(color: Chalk.dim),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Chalk.line(.45), width: 1.6),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Chalk.line(.45), width: 1.6),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Chalk.yellow, width: 2.2),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Chalk.boardRaised,
        shape: ChalkBorder(side: chalkLine, radius: 22),
        titleTextStyle: text.headlineSmall,
        contentTextStyle: text.bodyLarge,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: Chalk.boardRaised,
        showDragHandle: true,
        dragHandleColor: Chalk.line(.5),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Chalk.boardHigh,
        shape: ChalkBorder(side: chalkLine, radius: 14),
        textStyle: text.bodyLarge,
      ),
      listTileTheme: ListTileThemeData(
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodySmall,
        iconColor: Chalk.dim,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 74,
        backgroundColor: Chalk.boardDeep,
        indicatorColor: Chalk.yellow.withValues(alpha: .14),
        indicatorShape: const ChalkBorder(
          side: BorderSide(color: Chalk.yellow, width: 1.6),
          radius: 999,
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (st) => IconThemeData(
            color: st.contains(WidgetState.selected) ? Chalk.yellow : Chalk.dim,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (st) => mono(
            size: 11,
            weight: 700,
            spacing: 1.2,
            color: st.contains(WidgetState.selected) ? Chalk.yellow : Chalk.dim,
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: Chalk.line(.18),
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: Chalk.yellow,
        unselectedLabelColor: Chalk.dim,
        labelStyle: text.titleMedium,
        unselectedLabelStyle: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w400,
        ),
        indicator: const UnderlineTabIndicator(
          borderRadius: BorderRadius.all(Radius.circular(2)),
          borderSide: BorderSide(width: 3, color: Chalk.yellow),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Chalk.white,
        contentTextStyle: text.bodyLarge?.copyWith(color: Chalk.board),
        shape: const ChalkBorder(radius: 14),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        // ignore: deprecated_member_use
        year2023: false,
        color: Chalk.yellow,
        linearTrackColor: Color(0x33EDEFE6),
        circularTrackColor: Color(0x33EDEFE6),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected) ? Chalk.board : Chalk.dim,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected)
              ? Chalk.yellow
              : Colors.transparent,
        ),
      ),
      radioTheme: const RadioThemeData(
        fillColor: WidgetStatePropertyAll(Chalk.yellow),
      ),
      badgeTheme: const BadgeThemeData(
        backgroundColor: Chalk.pink,
        textColor: Chalk.board,
      ),
      dividerTheme: DividerThemeData(color: Chalk.line(.18), space: 1),
      iconTheme: const IconThemeData(color: Chalk.white),
    );
  }
}

/// Colores de estado de reportes y asistencia (tizas).
extension StatusColors on ColorScheme {
  Color get confirmed => Chalk.green;
  Color get pending => Chalk.yellow;
  Color get rejected => Chalk.pink;

  /// Lo que se celebra: MVP, el primero de la tabla, logros.
  Color get mvpGold => Chalk.orange;
}
