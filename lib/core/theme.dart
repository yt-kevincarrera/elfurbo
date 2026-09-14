import 'package:flutter/material.dart';

/// Tema de la app: verde césped, Material 3, con variante oscura.
class AppTheme {
  static const seed = Color(0xFF1B5E20);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
      ),
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
  Color get mvpGold => const Color(0xFFFFB300);
}
