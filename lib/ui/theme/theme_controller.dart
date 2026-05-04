import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives light/dark switching, accent color, and global text color
/// customization for the whole app via [Provider].
class ThemeController extends ChangeNotifier {
  /// Default signature deep purple.
  static const Color defaultAccentColor = Color(0xFF7B2CBF);

  /// Starts in dark mode (default listening experience).
  ThemeMode _mode = ThemeMode.dark;

  /// Current accent color (defaults to signature purple).
  Color _accentColor = defaultAccentColor;

  /// Current custom text color. `null` means "auto" — derive from the
  /// active brightness (white on dark, dark-grey on light).
  Color? _customTextColor;

  ThemeController() {
    _loadPreferences();
  }

  /// Current Flutter [ThemeMode].
  ThemeMode get mode => _mode;

  /// True when using the dark palette.
  bool get isDark => _mode == ThemeMode.dark;

  /// Current accent color.
  Color get accentColor => _accentColor;

  /// User-chosen text color, or `null` when following the theme default
  /// ("auto"). UI uses this to decide whether to show the "Default"
  /// reset affordance and which color to paint in the settings circle.
  Color? get customTextColor => _customTextColor;

  /// True when the user has explicitly picked a text color that overrides
  /// the automatic theme-based default.
  bool get hasCustomTextColor => _customTextColor != null;

  /// Resolves the user's text color preference into a concrete [Color]
  /// for the given brightness. If the user has picked a custom color
  /// via the settings picker it wins regardless of theme; otherwise we
  /// fall back to the automatic theme default — white on dark, near
  /// black on light.
  Color textColorFor(Brightness brightness) {
    final custom = _customTextColor;
    if (custom != null) return custom;
    return brightness == Brightness.dark
        ? Colors.white
        : const Color(0xFF1A1A1A);
  }

  /// Load saved preferences from shared_preferences.
  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDarkMode = prefs.getBool('isDarkMode') ?? true;
      _mode = isDarkMode ? ThemeMode.dark : ThemeMode.light;

      final accentValue = prefs.getInt('accentColor');
      if (accentValue != null) {
        _accentColor = Color(accentValue);
      }

      final textValue = prefs.getInt('customTextColor');
      if (textValue != null) {
        _customTextColor = Color(textValue);
      }

      notifyListeners();
    } catch (e) {
      // Ignore errors, use defaults
    }
  }

  /// Toggles between light and dark.
  Future<void> toggle() async {
    _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isDarkMode', isDark);
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Sets an explicit mode.
  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isDarkMode', isDark);
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Sets a custom accent color and persists it.
  Future<void> setAccentColor(Color color) async {
    _accentColor = color;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('accentColor', color.value & 0xFFFFFFFF);
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Resets accent color to default purple.
  Future<void> resetAccentColor() async {
    _accentColor = defaultAccentColor;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('accentColor');
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Sets the global text color override to [color] and persists it so
  /// the choice survives app restarts. Pass any [Color] — the color
  /// picker in settings produces the full RGB range, not just
  /// black/white.
  Future<void> setCustomTextColor(Color color) async {
    _customTextColor = color;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('customTextColor', color.value & 0xFFFFFFFF);
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Clears the text color override, returning to the automatic theme
  /// default (white on dark, near-black on light).
  Future<void> resetTextColor() async {
    _customTextColor = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('customTextColor');
    } catch (e) {
      // Ignore save errors
    }
  }
}
