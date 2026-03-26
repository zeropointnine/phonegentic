import 'package:flutter/material.dart';

class AppColors {
  static bool _isDark = true;

  static void _update(bool isDark) => _isDark = isDark;

  // ── Backgrounds ──
  static Color get bg =>
      _isDark ? const Color(0xFF100D08) : const Color(0xFFF0E6D8);
  static Color get surface =>
      _isDark ? const Color(0xFF1A1610) : const Color(0xFFF5EDE2);
  static Color get card =>
      _isDark ? const Color(0xFF252018) : const Color(0xFFF8F0E5);
  static Color get border =>
      _isDark ? const Color(0xFF3A3228) : const Color(0xFFE0CDBA);

  // ── Text ──
  static Color get textPrimary =>
      _isDark ? const Color(0xFFFFD27A) : const Color(0xFF18120A);
  static Color get textSecondary =>
      _isDark ? const Color(0xFFC9943A) : const Color(0xFF5C4D38);
  static Color get textTertiary =>
      _isDark ? const Color(0xFF7A5C28) : const Color(0xFF9B8B72);

  // ── CRT Amber Phosphor palette (constant across themes) ──
  static const Color phosphor = Color(0xFFFFB347);
  static const Color hotSignal = Color(0xFFFFD27A);
  static const Color burntAmber = Color(0xFFC97A1A);
  static const Color crtBlack = Color(0xFF0B0805);

  // Legacy aliases used throughout the codebase
  static const Color accent = phosphor;
  static const Color accentLight = hotSignal;
  static const Color green = Color(0xFF4ADE80);
  static const Color red = Color(0xFFEF4444);
  static const Color orange = Color(0xFFE8960F);
}

class ThemeProvider extends ChangeNotifier {
  ThemeData? currentTheme;
  bool _isDark = true;

  bool get isDark => _isDark;

  ThemeProvider() {
    currentTheme = _buildDarkTheme();
  }

  void toggle() {
    _isDark = !_isDark;
    AppColors._update(_isDark);
    currentTheme = _isDark ? _buildDarkTheme() : _buildLightTheme();
    notifyListeners();
  }

  void setLightMode() {
    _isDark = false;
    AppColors._update(false);
    currentTheme = _buildLightTheme();
    notifyListeners();
  }

  void setDarkmode() {
    _isDark = true;
    AppColors._update(true);
    currentTheme = _buildDarkTheme();
    notifyListeners();
  }

  ThemeData _buildDarkTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF100D08),
      colorScheme: ColorScheme.dark(
        primary: AppColors.phosphor,
        secondary: AppColors.hotSignal,
        surface: const Color(0xFF1A1610),
        error: AppColors.red,
        onPrimary: AppColors.crtBlack,
        onSecondary: AppColors.crtBlack,
        onSurface: const Color(0xFFFFD27A),
        onError: Colors.white,
        outline: const Color(0xFF3A3228),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Color(0xFFFFD27A),
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: Color(0xFFC97A1A)),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF252018),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF3A3228), width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1A1610),
        hintStyle: const TextStyle(color: Color(0xFF7A5C28), fontSize: 14),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF3A3228)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF3A3228)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide:
              const BorderSide(color: AppColors.phosphor, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.phosphor,
          foregroundColor: AppColors.crtBlack,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.phosphor,
          textStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      dividerTheme:
          const DividerThemeData(color: Color(0xFF3A3228), thickness: 0.5),
      iconTheme: const IconThemeData(color: Color(0xFFC97A1A)),
    );
  }

  ThemeData _buildLightTheme() {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF0E6D8),
      colorScheme: ColorScheme.light(
        primary: AppColors.burntAmber,
        secondary: AppColors.phosphor,
        surface: const Color(0xFFF5EDE2),
        error: AppColors.red,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: const Color(0xFF18120A),
        outline: const Color(0xFFE0CDBA),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Color(0xFF18120A),
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: Color(0xFFC97A1A)),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFFF8F0E5),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFE0CDBA), width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF5EDE2),
        hintStyle: const TextStyle(color: Color(0xFF9B8B72), fontSize: 14),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE0CDBA)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE0CDBA)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide:
              const BorderSide(color: AppColors.burntAmber, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.burntAmber,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.burntAmber,
          textStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      dividerTheme:
          const DividerThemeData(color: Color(0xFFE0CDBA), thickness: 0.5),
      iconTheme: const IconThemeData(color: Color(0xFFC97A1A)),
    );
  }
}
