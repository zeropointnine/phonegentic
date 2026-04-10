import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppTheme { amberVt100, miamiVice, light }

class AppColors {
  static AppTheme _theme = AppTheme.amberVt100;

  static void _update(AppTheme theme) => _theme = theme;

  static bool get _isMiami => _theme == AppTheme.miamiVice;
  static bool get _isLight => _theme == AppTheme.light;

  // ── Backgrounds ──
  static Color get bg => _isLight
      ? const Color(0xFFF0E6D8)
      : _isMiami
          ? const Color(0xFF080A14)
          : const Color(0xFF100D08);

  static Color get surface => _isLight
      ? const Color(0xFFF5EDE2)
      : _isMiami
          ? const Color(0xFF101626)
          : const Color(0xFF1A1610);

  static Color get card => _isLight
      ? const Color(0xFFF8F0E5)
      : _isMiami
          ? const Color(0xFF1C2240)
          : const Color(0xFF252018);

  static Color get border => _isLight
      ? const Color(0xFFE0CDBA)
      : _isMiami
          ? const Color(0xFF303860)
          : const Color(0xFF3A3228);

  // ── Text ──
  static Color get textPrimary => _isLight
      ? const Color(0xFF18120A)
      : _isMiami
          ? const Color(0xFF00E5FF)
          : const Color(0xFFFFD27A);

  static Color get textSecondary => _isLight
      ? const Color(0xFF5C4D38)
      : _isMiami
          ? const Color(0xFF72D5D0)
          : const Color(0xFFC9943A);

  static Color get textTertiary => _isLight
      ? const Color(0xFF9B8B72)
      : _isMiami
          ? const Color(0xFF507888)
          : const Color(0xFF7A5C28);

  // ── Accent palette (theme-aware) ──
  //
  // Amber VT-100: warm CRT phosphor golds
  // Miami Vice:   cyan primary, hot pink signal, electric purple mid-tone
  //               (purple bridges cyan ↔ magenta on the color wheel)
  static Color get phosphor =>
      _isMiami ? const Color(0xFF00E5FF) : const Color(0xFFFFB347);
  static Color get hotSignal =>
      _isMiami ? const Color(0xFFFF3CA0) : const Color(0xFFFFD27A);
  static Color get burntAmber =>
      _isMiami ? const Color(0xFF8B5CF6) : const Color(0xFFC97A1A);
  static Color get crtBlack =>
      _isMiami ? const Color(0xFF050710) : const Color(0xFF0B0805);

  static Color get accent => phosphor;
  static Color get accentLight => hotSignal;
  static Color get onAccent =>
      _isMiami ? const Color(0xFF001A22) : const Color(0xFF3D2200);
  static Color get green =>
      _isMiami ? const Color(0xFF00FFAB) : const Color(0xFF4ADE80);
  static Color get red =>
      _isMiami ? const Color(0xFFFF4081) : const Color(0xFFE06A1D);
  static Color get orange =>
      _isMiami ? const Color(0xFFFFAB91) : const Color(0xFFE8960F);
}

/// Drop-in tappable wrapper with cursor change + visible hover feedback.
///
/// Replaces the `MouseRegion(cursor: click, child: GestureDetector(...))` pattern
/// with a single widget that also lights up on hover.
class HoverButton extends StatefulWidget {
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final BorderRadius borderRadius;
  final Color? hoverColor;
  final EdgeInsets padding;
  final String? tooltip;

  const HoverButton({
    super.key,
    this.onTap,
    this.onLongPress,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.hoverColor,
    this.padding = EdgeInsets.zero,
    this.tooltip,
  });

  @override
  State<HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<HoverButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color tint = widget.hoverColor ??
        AppColors.accent.withValues(alpha: 0.10);

    Widget result = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.padding,
          foregroundDecoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            color: _hovered ? tint : Colors.transparent,
          ),
          child: widget.child,
        ),
      ),
    );

    if (widget.tooltip != null) {
      result = Tooltip(message: widget.tooltip!, child: result);
    }

    return result;
  }
}

class ThemeProvider extends ChangeNotifier {
  static const _prefKey = 'app_theme';

  ThemeData? currentTheme;
  AppTheme _appTheme = AppTheme.amberVt100;

  AppTheme get appTheme => _appTheme;
  bool get isDark => _appTheme != AppTheme.light;

  ThemeProvider() {
    currentTheme = _buildAmberDarkTheme();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_prefKey);
    if (name == null) return;
    final saved = AppTheme.values.cast<AppTheme?>().firstWhere(
          (t) => t!.name == name,
          orElse: () => null,
        );
    if (saved != null && saved != _appTheme) {
      setTheme(saved);
    }
  }

  void setTheme(AppTheme theme) {
    _appTheme = theme;
    AppColors._update(theme);
    switch (theme) {
      case AppTheme.amberVt100:
        currentTheme = _buildAmberDarkTheme();
        break;
      case AppTheme.miamiVice:
        currentTheme = _buildMiamiViceTheme();
        break;
      case AppTheme.light:
        currentTheme = _buildLightTheme();
        break;
    }
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString(_prefKey, theme.name));
  }

  void toggle() {
    if (_appTheme == AppTheme.light) {
      setTheme(AppTheme.amberVt100);
    } else {
      setTheme(AppTheme.light);
    }
  }

  void setLightMode() => setTheme(AppTheme.light);
  void setDarkmode() => setTheme(AppTheme.amberVt100);

  // ─────────────────────────────────────────────
  // Amber VT-100 (dark)
  // ─────────────────────────────────────────────

  ThemeData _buildAmberDarkTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF100D08),
      colorScheme: ColorScheme.dark(
        primary: AppColors.phosphor,
        secondary: AppColors.hotSignal,
        surface: const Color(0xFF1A1610),
        error: AppColors.red,
        onPrimary: AppColors.onAccent,
        onSecondary: AppColors.onAccent,
        onSurface: const Color(0xFFFFD27A),
        onError: AppColors.onAccent,
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
          borderSide: BorderSide(color: AppColors.phosphor, width: 1.5),
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

  // ─────────────────────────────────────────────
  // Miami Vice (dark) — cyan / hot pink / purple
  // ─────────────────────────────────────────────

  ThemeData _buildMiamiViceTheme() {
    const bg = Color(0xFF080A14);
    const surface = Color(0xFF101626);
    const card = Color(0xFF1C2240);
    const borderColor = Color(0xFF303860);
    const textPrimary = Color(0xFF00E5FF);
    const textHint = Color(0xFF507888);
    const iconColor = Color(0xFF8B5CF6);

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.dark(
        primary: const Color(0xFF00E5FF),
        secondary: const Color(0xFFFF3CA0),
        surface: surface,
        error: const Color(0xFFFF4081),
        onPrimary: const Color(0xFF001A22),
        onSecondary: const Color(0xFF2A0020),
        onSurface: textPrimary,
        onError: const Color(0xFF001A22),
        outline: borderColor,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: iconColor),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: borderColor, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: const TextStyle(color: textHint, fontSize: 14),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: textPrimary, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00E5FF),
          foregroundColor: const Color(0xFF050710),
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
          foregroundColor: const Color(0xFF00E5FF),
          textStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      dividerTheme:
          const DividerThemeData(color: borderColor, thickness: 0.5),
      iconTheme: const IconThemeData(color: iconColor),
    );
  }

  // ─────────────────────────────────────────────
  // Light (amber-based)
  // ─────────────────────────────────────────────

  ThemeData _buildLightTheme() {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF0E6D8),
      colorScheme: ColorScheme.light(
        primary: AppColors.burntAmber,
        secondary: AppColors.phosphor,
        surface: const Color(0xFFF5EDE2),
        error: AppColors.red,
        onPrimary: AppColors.onAccent,
        onSecondary: AppColors.onAccent,
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
          borderSide: BorderSide(color: AppColors.burntAmber, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.burntAmber,
          foregroundColor: AppColors.onAccent,
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
