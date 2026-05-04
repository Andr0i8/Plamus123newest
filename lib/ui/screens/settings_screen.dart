import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';

import '../theme/theme_controller.dart';

/// Settings screen with accent color and text color customization.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeCtrl = context.watch<ThemeController>();

    // Resolve the "effective" text color shown in the settings circle.
    // When the user hasn't picked a custom one, fall back to the
    // automatic default for the currently active theme so the circle
    // still shows what would actually be painted across the app.
    final effectiveTextColor =
        themeCtrl.textColorFor(theme.brightness);

    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
              child: Text(
                'Settings',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Appearance',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: Icon(
                      themeCtrl.isDark
                          ? Icons.dark_mode_outlined
                          : Icons.light_mode_outlined,
                    ),
                    title: const Text('Theme'),
                    subtitle: Text(themeCtrl.isDark ? 'Dark' : 'Light'),
                    trailing: Switch(
                      value: themeCtrl.isDark,
                      onChanged: (_) => themeCtrl.toggle(),
                    ),
                    onTap: themeCtrl.toggle,
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    leading: Icon(
                      Icons.palette_outlined,
                      color: themeCtrl.accentColor,
                    ),
                    title: const Text('Accent color'),
                    subtitle: Text(
                      'Customize your theme color',
                      style: TextStyle(color: themeCtrl.accentColor),
                    ),
                    trailing: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: themeCtrl.accentColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.dividerColor,
                          width: 2,
                        ),
                      ),
                    ),
                    onTap: () => _showAccentColorPicker(context, themeCtrl),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: TextButton.icon(
                      onPressed: () => themeCtrl.resetAccentColor(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset to default purple'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Text color: mirrors the accent-color row exactly so
                  // the two settings feel like siblings — a ListTile
                  // with a color swatch that opens the same full-range
                  // color picker the accent uses. "Default" below it
                  // clears the override and returns to the automatic
                  // theme behavior (white on dark, near-black on light).
                  ListTile(
                    leading: Icon(
                      Icons.format_color_text,
                      color: effectiveTextColor,
                    ),
                    title: const Text('Text color'),
                    subtitle: Text(
                      themeCtrl.hasCustomTextColor
                          ? 'Custom color applied across the app'
                          : 'Follows theme (white on dark, black on light)',
                    ),
                    trailing: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: effectiveTextColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          // When the user hasn't picked a custom color
                          // the circle can end up painted in the SAME
                          // shade as the divider (e.g. white text on
                          // dark surface); use the accent color as a
                          // fallback so the swatch is always visible.
                          color: themeCtrl.hasCustomTextColor
                              ? theme.dividerColor
                              : theme.colorScheme.primary
                                  .withValues(alpha: 0.5),
                          width: 2,
                        ),
                      ),
                    ),
                    onTap: () => _showTextColorPicker(context, themeCtrl),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: TextButton.icon(
                      onPressed: themeCtrl.resetTextColor,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Default'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Full-RGB color picker for the accent color.
  void _showAccentColorPicker(
    BuildContext context,
    ThemeController themeCtrl,
  ) {
    Color pickerColor = themeCtrl.accentColor;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Pick accent color'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: pickerColor,
              onColorChanged: (color) {
                pickerColor = color;
              },
              pickerAreaHeightPercent: 0.8,
              enableAlpha: false,
              displayThumbColor: true,
              labelTypes: const [],
              pickerAreaBorderRadius: BorderRadius.circular(16),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                themeCtrl.setAccentColor(pickerColor);
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );
  }

  /// Full-RGB color picker for the global text color. Reuses the same
  /// `flutter_colorpicker` widget as the accent picker so the two
  /// settings feel identical. The initial swatch is the user's
  /// existing choice or — if they're still on "auto" — the current
  /// theme's effective text color, so the picker doesn't open on a
  /// random black square.
  void _showTextColorPicker(
    BuildContext context,
    ThemeController themeCtrl,
  ) {
    Color pickerColor = themeCtrl.customTextColor ??
        themeCtrl.textColorFor(Theme.of(context).brightness);

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Pick text color'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: pickerColor,
              onColorChanged: (color) {
                pickerColor = color;
              },
              pickerAreaHeightPercent: 0.8,
              enableAlpha: false,
              displayThumbColor: true,
              labelTypes: const [],
              pickerAreaBorderRadius: BorderRadius.circular(16),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                themeCtrl.setCustomTextColor(pickerColor);
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );
  }
}
