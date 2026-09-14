import 'package:flutter/material.dart';

/// Tema de la app: dorado sobre negro, Material 3.
///
/// La variante oscura es la principal (fondos negros, acentos dorados). La
/// clara usa un dorado más profundo sobre blanco cálido para que el texto y
/// los botones sigan teniendo contraste.
class AppTheme {
  /// Dorado principal (ícono, notificaciones, acentos en modo oscuro).
  static const gold = Color(0xFFE0B84A);

  /// Dorado profundo para modo claro (contrasta sobre blanco).
  static const goldDeep = Color(0xFF8A6A12);

  static const black = Color(0xFF0A0A0A);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ColorScheme _scheme(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: gold,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    if (brightness == Brightness.dark) {
      return base.copyWith(
        primary: gold,
        onPrimary: const Color(0xFF231A00),
        primaryContainer: const Color(0xFF3A2D05),
        onPrimaryContainer: const Color(0xFFFFE08A),
        secondary: const Color(0xFFD6C48E),
        onSecondary: const Color(0xFF231A00),
        secondaryContainer: const Color(0xFF2E2A1E),
        onSecondaryContainer: const Color(0xFFF3E6C0),
        tertiary: const Color(0xFFBDBDBD),
        surface: black,
        onSurface: const Color(0xFFF2EFE6),
        onSurfaceVariant: const Color(0xFFB8B2A0),
        surfaceContainerLowest: const Color(0xFF000000),
        surfaceContainerLow: const Color(0xFF141414),
        surfaceContainer: const Color(0xFF1B1B1B),
        surfaceContainerHigh: const Color(0xFF232323),
        surfaceContainerHighest: const Color(0xFF2C2C2C),
        outline: const Color(0xFF5C574A),
        outlineVariant: const Color(0xFF33302A),
        inverseSurface: const Color(0xFFF2EFE6),
        onInverseSurface: black,
        inversePrimary: goldDeep,
      );
    }
    return base.copyWith(
      primary: goldDeep,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFFFE08A),
      onPrimaryContainer: const Color(0xFF231A00),
      secondary: const Color(0xFF2B2B2B),
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFEDE5CF),
      onSecondaryContainer: const Color(0xFF231A00),
      surface: const Color(0xFFFCFAF4),
      onSurface: const Color(0xFF141414),
      onSurfaceVariant: const Color(0xFF524B3B),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF5F1E6),
      surfaceContainer: const Color(0xFFEFEADB),
      surfaceContainerHigh: const Color(0xFFE9E3D2),
      surfaceContainerHighest: const Color(0xFFE2DBC8),
      outline: const Color(0xFF837B66),
      outlineVariant: const Color(0xFFD3CBB5),
      inversePrimary: gold,
    );
  }

  static ThemeData _base(Brightness brightness) {
    final scheme = _scheme(brightness);
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: isDark ? gold : scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        color: scheme.surfaceContainerLow,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(visualDensity: VisualDensity.compact),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      navigationBarTheme: NavigationBarThemeData(
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primaryContainer,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    );
  }
}

/// Colores semánticos para estados de reportes y asistencia.
extension StatusColors on ColorScheme {
  Color get confirmed => brightness == Brightness.dark
      ? const Color(0xFF81C784)
      : const Color(0xFF2E7D32);
  Color get pending => brightness == Brightness.dark
      ? const Color(0xFFFFD54F)
      : const Color(0xFFF9A825);
  Color get rejected => error;
  Color get mvpGold => AppTheme.gold;
}
