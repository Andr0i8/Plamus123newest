import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives light/dark switching, accent color, and global text color
/// customization for the whole app via [Provider].
///
/// Text-color customization is stored **per brightness**:
/// `_customTextColors[Brightness.dark]` is independent from
/// `_customTextColors[Brightness.light]`. This is what fixes the
/// "switching to light theme leaves text white-on-white" bug — when
/// the user explicitly sets a custom color in one mode, the other
/// mode keeps following the automatic theme default until they
/// customize it too. The previous shared-value model couldn't
/// distinguish "user wants white text everywhere" from "user picked
/// white for the dark theme only", so a custom color leaked into the
/// other theme and silently destroyed legibility.
class ThemeController extends ChangeNotifier {
  /// SharedPreferences key for the "Show track artwork" toggle. Exposed
  /// as a constant so non-Provider readers (e.g. [AudioPlayerService])
  /// can stay in sync with the UI preference without needing a Provider
  /// context.
  static const String showArtworkPrefKey = 'showArtwork';

  /// Default signature deep purple.
  static const Color defaultAccentColor = Color(0xFF7B2CBF);

  /// Legacy single-value text-color preference key (pre-fix). Migrated
  /// into [_prefCustomTextDark] / [_prefCustomTextLight] on first load,
  /// then ignored.
  static const String _prefLegacyCustomText = 'customTextColor';

  /// Per-brightness keys for the migrated, theme-aware custom text
  /// color preference.
  static const String _prefCustomTextDark = 'customTextColor_dark';
  static const String _prefCustomTextLight = 'customTextColor_light';

  /// Starts in dark mode (default listening experience).
  ThemeMode _mode = ThemeMode.dark;

  /// Current accent color (defaults to signature purple).
  Color _accentColor = defaultAccentColor;

  /// Custom text color overrides, keyed by [Brightness]. A missing
  /// entry means "auto" — derive from the active brightness (white on
  /// dark, near-black on light).
  final Map<Brightness, Color> _customTextColors = <Brightness, Color>{};

  /// Whether downloaded cover artwork should be displayed in track
  /// tiles, the player bar and the now-playing screen. Default: on.
  /// Persisted under [showArtworkPrefKey].
  bool _showArtwork = true;

  ThemeController() {
    _loadPreferences();
  }

  /// Current Flutter [ThemeMode].
  ThemeMode get mode => _mode;

  /// True when using the dark palette.
  bool get isDark => _mode == ThemeMode.dark;

  /// Current accent color.
  Color get accentColor => _accentColor;

  /// Internal helper: derive the [Brightness] that matches the active
  /// [ThemeMode]. We treat [ThemeMode.system] as dark for now because
  /// Plamus doesn't track system brightness explicitly — every UI
  /// surface that needs brightness reads it from `Theme.of(context)`
  /// instead, so this getter is only used to pick the default target
  /// for `setCustomTextColor()` / `resetTextColor()` when the caller
  /// doesn't specify one.
  Brightness get _activeBrightness =>
      _mode == ThemeMode.light ? Brightness.light : Brightness.dark;

  /// User-chosen text color for the currently active theme, or `null`
  /// when that theme is still following the automatic default. The
  /// settings UI uses this to decide whether to show the "Default"
  /// reset affordance.
  Color? get customTextColor => _customTextColors[_activeBrightness];

  /// True when the user has explicitly picked a text color for the
  /// currently active theme.
  bool get hasCustomTextColor => customTextColor != null;

  /// Whether track artwork should be rendered across the UI. Reactive
  /// — widgets watching the controller rebuild when the user toggles
  /// this in Settings.
  bool get showArtwork => _showArtwork;

  /// Resolves the user's text-color preference into a concrete [Color]
  /// for the given brightness. If the user has picked a custom color
  /// for THAT brightness it wins; otherwise we fall back to the
  /// automatic theme default — white on dark, near-black on light.
  ///
  /// This is the core of the "theme switch updates text color" fix:
  /// whichever brightness the [MaterialApp] is currently rendering, we
  /// look up THAT brightness's slot. Switching between dark and light
  /// now always picks the right slot, and a custom color set in one
  /// mode can't bleed into the other.
  Color textColorFor(Brightness brightness) {
    final custom = _customTextColors[brightness];
    if (custom != null) return custom;
    return brightness == Brightness.dark
        ? Colors.white
        : const Color(0xFF1A1A1A);
  }

  /// Load saved preferences from shared_preferences.
  ///
  /// Includes a one-shot migration from the legacy single-value
  /// `customTextColor` key (which set both themes at once) to the new
  /// per-brightness slots: the legacy color is applied to the theme
  /// the user is currently in so an existing customization isn't lost
  /// on first run after the upgrade. The other brightness stays on
  /// "auto" so theme switches now produce a legible default again.
  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDarkMode = prefs.getBool('isDarkMode') ?? true;
      _mode = isDarkMode ? ThemeMode.dark : ThemeMode.light;

      final accentValue = prefs.getInt('accentColor');
      if (accentValue != null) {
        _accentColor = Color(accentValue);
      }

      final darkText = prefs.getInt(_prefCustomTextDark);
      if (darkText != null) {
        _customTextColors[Brightness.dark] = Color(darkText);
      }
      final lightText = prefs.getInt(_prefCustomTextLight);
      if (lightText != null) {
        _customTextColors[Brightness.light] = Color(lightText);
      }

      // Migrate the legacy combined key. Only fires when neither of
      // the per-brightness keys has been written yet — once the user
      // saves a per-brightness color we treat the legacy value as
      // discarded.
      if (_customTextColors.isEmpty) {
        final legacy = prefs.getInt(_prefLegacyCustomText);
        if (legacy != null) {
          _customTextColors[_activeBrightness] = Color(legacy);
        }
      }

      _showArtwork = prefs.getBool(showArtworkPrefKey) ?? true;

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
      await prefs.setInt('accentColor', color.toARGB32());
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

  /// Sets the text-color override for [brightness] (defaults to the
  /// active theme's brightness) and persists it so the choice survives
  /// app restarts. Pass any [Color] — the color picker in settings
  /// produces the full RGB range, not just black/white.
  ///
  /// Because the override is scoped to a single brightness, choosing
  /// white text in dark mode won't strand the user with white-on-white
  /// text once they flip to light mode. The other brightness keeps
  /// following its automatic default until the user customizes it
  /// from that theme.
  Future<void> setCustomTextColor(
    Color color, {
    Brightness? brightness,
  }) async {
    final target = brightness ?? _activeBrightness;
    _customTextColors[target] = color;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        target == Brightness.dark ? _prefCustomTextDark : _prefCustomTextLight,
        color.toARGB32(),
      );
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Clears the text color override for [brightness] (defaults to the
  /// active theme's brightness), returning that brightness to its
  /// automatic default — white on dark, near-black on light. Leaves
  /// the other brightness's custom color (if any) untouched.
  Future<void> resetTextColor({Brightness? brightness}) async {
    final target = brightness ?? _activeBrightness;
    _customTextColors.remove(target);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(
        target == Brightness.dark ? _prefCustomTextDark : _prefCustomTextLight,
      );
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Toggles whether track artwork is shown across the UI and persists
  /// the choice. Notifies listeners so every consumer (track tiles, the
  /// player bar, the now-playing screen) rebuilds in lockstep.
  Future<void> setShowArtwork(bool value) async {
    if (_showArtwork == value) return;
    _showArtwork = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(showArtworkPrefKey, value);
    } catch (e) {
      // Ignore save errors — runtime state still updates.
    }
  }
}
