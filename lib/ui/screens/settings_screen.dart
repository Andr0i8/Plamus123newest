import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';

import '../../services/audio_player_service.dart';
import '../../services/library_service.dart';
import '../theme/theme_controller.dart';

/// Settings screen with appearance + library customization plus the
/// "Clear all data" reset action.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// GitHub repository URL surfaced as a small footer link. Tapping it
  /// copies the URL to the clipboard so users on offline / sandboxed
  /// machines can still grab the address without needing
  /// `url_launcher` (an extra plugin we don't otherwise need).
  static const String _githubUrl = 'https://github.com/Andr0i8/Plamus';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeCtrl = context.watch<ThemeController>();

    // Resolve the "effective" text color shown in the settings circle.
    // When the user hasn't picked a custom one, fall back to the
    // automatic default for the currently active theme so the circle
    // still shows what would actually be painted across the app.
    final effectiveTextColor = themeCtrl.textColorFor(theme.brightness);

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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                          ? 'Custom color applied to '
                              '${themeCtrl.isDark ? 'dark' : 'light'} theme'
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: TextButton.icon(
                      onPressed: themeCtrl.resetTextColor,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Default'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Library',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // "Show track artwork" toggle. When OFF the UI behaves
                  // exactly like the pre-artwork build: track tiles use
                  // the like-icon leading and the player surfaces fall
                  // back to the placeholder. When ON, every track that
                  // has a sibling thumbnail JPG (downloaded alongside
                  // the audio) renders it; tracks without artwork keep
                  // showing the placeholder.
                  ListTile(
                    leading: Icon(
                      themeCtrl.showArtwork
                          ? Icons.photo_library
                          : Icons.photo_library_outlined,
                      color: themeCtrl.accentColor,
                    ),
                    title: const Text('Show track artwork'),
                    subtitle: Text(
                      themeCtrl.showArtwork
                          ? 'YouTube thumbnails appear in tiles and the player bar'
                          : 'Tracks render with a placeholder icon — no images',
                    ),
                    trailing: Switch(
                      value: themeCtrl.showArtwork,
                      onChanged: (v) {
                        themeCtrl.setShowArtwork(v);
                        // Mirror the value into the audio service so
                        // the cached preference stays in sync without
                        // waiting for a SharedPreferences round-trip.
                        context.read<AudioPlayerService>().setShowArtwork(v);
                      },
                    ),
                    onTap: () {
                      final next = !themeCtrl.showArtwork;
                      themeCtrl.setShowArtwork(next);
                      context
                          .read<AudioPlayerService>()
                          .setShowArtwork(next);
                    },
                  ),
                  const SizedBox(height: 32),
                  // "Danger zone" — a single destructive action that
                  // resets the app to a freshly-installed state.
                  // Visually tinted with the theme's error color so
                  // users understand the row is different from the
                  // ones above.
                  Text(
                    'Data',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: Icon(
                      Icons.delete_forever_outlined,
                      color: theme.colorScheme.error,
                    ),
                    title: Text(
                      'Clear all data',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    subtitle: const Text(
                      'Delete every track, playlist, history entry and '
                      'audio/artwork file on disk',
                    ),
                    onTap: () => _confirmClearAllData(context),
                  ),
                  const SizedBox(height: 24),
                  // Subtle GitHub link — small text aligned right, no
                  // button styling, taps copy the URL to clipboard +
                  // show a toast confirmation. Kept unobtrusive per
                  // the spec.
                  Align(
                    alignment: Alignment.centerRight,
                    child: _GithubFooterLink(url: _githubUrl),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Two-step confirmation flow for the "Clear all data" action.
  ///
  /// 1. Tap → AlertDialog explaining what will be deleted.
  /// 2. Confirm → audio playback is stopped (so Windows releases the
  ///    file lock on the currently-playing track) and the library
  ///    service wipes both the database and the on-disk audio /
  ///    artwork files.
  ///
  /// After the wipe, every Provider listener repaints with the empty
  /// state and the user sees the app as if freshly installed (modulo
  /// theme / accent preferences, which are not user content and stay
  /// per standard "Clear data" UX).
  Future<void> _confirmClearAllData(BuildContext context) async {
    // Capture handles BEFORE the dialog opens so we don't pass a stale
    // BuildContext across async gaps.
    final audio = context.read<AudioPlayerService>();
    final lib = context.read<LibraryService>();
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dialogTheme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('Clear all data?'),
          content: const Text(
            'This permanently deletes every track, playlist, and history '
            'entry from the database, and removes every audio + artwork '
            'file from your library folder.\n\nThis cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: dialogTheme.colorScheme.error,
                foregroundColor: dialogTheme.colorScheme.onError,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete everything'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      // Stop playback first — Windows holds an exclusive lock on the
      // currently-playing file via media_kit, and the per-file delete
      // inside [LibraryService.clearAllData] would silently skip it.
      await audio.stop();
      await lib.clearAllData();
      messenger.showSnackBar(
        const SnackBar(content: Text('All library data cleared.')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not clear data: $e')),
      );
    }
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

/// Subtle footer link to the Plamus GitHub repository. Renders as
/// small dimmed text aligned to the trailing edge of the settings
/// column; tapping it copies the URL to the clipboard and surfaces a
/// brief confirmation SnackBar.
///
/// We deliberately don't launch a browser (avoids adding a
/// `url_launcher` dependency just for this footer) — copying the URL
/// works on every platform Plamus targets and matches "small,
/// unobtrusive" from the spec.
class _GithubFooterLink extends StatelessWidget {
  const _GithubFooterLink({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dimmedColor =
        theme.textTheme.bodySmall?.color?.withValues(alpha: 0.55) ??
            theme.colorScheme.onSurface.withValues(alpha: 0.55);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        await Clipboard.setData(ClipboardData(text: url));
        messenger.showSnackBar(
          const SnackBar(
            content: Text('GitHub link copied to clipboard'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.code,
              size: 14,
              color: dimmedColor,
            ),
            const SizedBox(width: 6),
            Text(
              url,
              style: theme.textTheme.bodySmall?.copyWith(
                color: dimmedColor,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
