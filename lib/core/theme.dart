import 'package:flutter/material.dart';

/// Tema de la app, en la línea de Material 3 Expressive: paleta tonal a partir
/// de un verde de terreno, dorado para lo que se celebra (MVP, logros,
/// trofeos), formas muy redondeadas que se aprietan al pulsar, tipografía con
/// más peso en títulos y superficies por capas en vez de bordes.
class AppTheme {
  /// Color base de toda la paleta. Cambiar este valor recolorea la app.
  static const seed = Color(0xFF1B6E4F);

  /// Dorado del ícono: MVP, logros y trofeos (rol terciario).
  static const gold = Color(0xFFE0B84A);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ColorScheme scheme(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
    final golden = ColorScheme.fromSeed(
      seedColor: gold,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    return base.copyWith(
      tertiary: golden.primary,
      onTertiary: golden.onPrimary,
      tertiaryContainer: golden.primaryContainer,
      onTertiaryContainer: golden.onPrimaryContainer,
    );
  }

  /// Escala tipográfica "enfatizada": títulos con más peso y algo más
  /// apretados; el cuerpo se queda como en Material 3.
  static TextTheme _text(TextTheme t) => t.copyWith(
    displayLarge: t.displayLarge?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -1.5,
    ),
    displayMedium: t.displayMedium?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -1,
    ),
    displaySmall: t.displaySmall?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
    ),
    headlineLarge: t.headlineLarge?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
    ),
    headlineMedium: t.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    ),
    headlineSmall: t.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    labelMedium: t.labelMedium?.copyWith(fontWeight: FontWeight.w600),
  );

  /// Botones redondos que al pulsarlos se aprietan a esquinas más cuadradas
  /// (el cambio de forma lo anima el propio botón).
  static WidgetStateProperty<OutlinedBorder> _morphingShape([
    double pressedRadius = 12,
  ]) => WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.pressed)
        ? RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(pressedRadius),
          )
        : const StadiumBorder(),
  );

  static ButtonStyle _buttonStyle(TextTheme text) => ButtonStyle(
    shape: _morphingShape(),
    minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 24)),
    textStyle: WidgetStatePropertyAll(text.labelLarge?.copyWith(fontSize: 15)),
    animationDuration: const Duration(milliseconds: 220),
  );

  static ThemeData _base(Brightness brightness) {
    final s = scheme(brightness);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: s,
      brightness: brightness,
    );
    final text = _text(base.textTheme);
    final buttons = _buttonStyle(text);
    const sheetRadius = Radius.circular(28);

    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: s.surface,
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: s.surface,
        foregroundColor: s.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(
          color: s.onSurface,
          fontSize: 22,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: s.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      ),
      filledButtonTheme: FilledButtonThemeData(style: buttons),
      outlinedButtonTheme: OutlinedButtonThemeData(style: buttons),
      textButtonTheme: TextButtonThemeData(
        style: buttons.copyWith(
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(style: buttons),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          shape: _morphingShape(10),
          animationDuration: const Duration(milliseconds: 200),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: s.primaryContainer,
        foregroundColor: s.onPrimaryContainer,
        elevation: 2,
        highlightElevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        extendedSizeConstraints: const BoxConstraints.tightFor(height: 64),
        extendedPadding: const EdgeInsets.symmetric(horizontal: 24),
        extendedTextStyle: text.titleMedium,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          side: WidgetStatePropertyAll(BorderSide(color: s.outlineVariant)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (st) => st.contains(WidgetState.selected)
                ? s.secondaryContainer
                : Colors.transparent,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide.none,
        backgroundColor: s.surfaceContainerHigh,
        labelStyle: text.labelLarge,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: s.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 18,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: s.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: s.error, width: 1.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: s.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: text.headlineSmall?.copyWith(color: s.onSurface),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: s.surfaceContainerLow,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: sheetRadius),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: s.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: text.titleMedium?.copyWith(color: s.onSurface),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 76,
        backgroundColor: s.surfaceContainer,
        indicatorColor: s.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (st) => text.labelMedium?.copyWith(
            fontWeight: st.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: text.titleSmall,
        unselectedLabelStyle: text.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        indicator: UnderlineTabIndicator(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          borderSide: BorderSide(width: 3, color: s.primary),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: s.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(color: s.onInverseSurface),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        // Pista redondeada con hueco: la versión nueva de Material 3.
        // ignore: deprecated_member_use
        year2023: false,
        color: s.primary,
        linearTrackColor: s.secondaryContainer,
        circularTrackColor: s.secondaryContainer,
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected)
              ? const Icon(Icons.check, size: 16)
              : null,
        ),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: s.error,
        textColor: s.onError,
      ),
      dividerTheme: DividerThemeData(color: s.outlineVariant, space: 1),
    );
  }
}

/// Colores semánticos para estados de reportes y asistencia.
extension StatusColors on ColorScheme {
  Color get confirmed => brightness == Brightness.dark
      ? const Color(0xFF8BD6A6)
      : const Color(0xFF1E7D45);
  Color get pending => brightness == Brightness.dark
      ? const Color(0xFFF2C76B)
      : const Color(0xFF9A6B00);
  Color get rejected => error;

  /// Dorado de MVP, logros y trofeos.
  Color get mvpGold => tertiary;
}
