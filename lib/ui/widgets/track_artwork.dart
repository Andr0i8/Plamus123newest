import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/track_model.dart';
import '../theme/theme_controller.dart';

/// Renders the cover art for a single [TrackModel].
///
/// Reads [ThemeController.showArtwork] so the entire app can hide every
/// thumbnail with a single toggle from the Settings screen — when the
/// user turns it off this widget always falls back to the placeholder,
/// even for tracks that DO have a stored `artworkPath`.
///
/// Falls back to the existing music-note placeholder whenever:
///   * the user disabled artwork in Settings, OR
///   * the track was imported as a local file (no `artworkPath`), OR
///   * the artwork file used to exist but has since been deleted on
///     disk (e.g. the user wiped the library folder manually) — the
///     `Image.file` widget detects this via [errorBuilder] and we fall
///     back the same way as if the path had been null all along.
class TrackArtwork extends StatelessWidget {
  /// Creates a track artwork widget.
  const TrackArtwork({
    super.key,
    required this.track,
    required this.size,
    this.borderRadius,
    this.placeholderIconSize,
    this.fallbackIcon = Icons.music_note,
    this.elevation = 0,
  });

  /// The track whose [TrackModel.artworkPath] the widget should render.
  final TrackModel track;

  /// Side length in logical pixels. The widget is always square; if a
  /// non-square layout is needed, wrap this in an [AspectRatio] /
  /// [SizedBox] and pass the matching `size` for the fallback path.
  final double size;

  /// Corner radius of both the image clip and the placeholder square.
  /// Defaults to a `size / 8` round so small tiles get tight corners
  /// and large covers (mobile player screen) get a bigger sweep.
  final BorderRadius? borderRadius;

  /// Optional override for the placeholder icon size. Defaults to
  /// `size * 0.45` which matches the existing player-screen / mini-player
  /// proportions.
  final double? placeholderIconSize;

  /// Icon to render in the placeholder when no artwork file is shown.
  final IconData fallbackIcon;

  /// Material elevation for the rendered card. Track tiles pass 0 for a
  /// flat look; the desktop player bar uses a small elevation to lift
  /// the cover off the glass background.
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Watching ThemeController triggers a rebuild when the user toggles
    // the "Show track artwork" preference, so every consumer of this
    // widget reacts in lockstep without manual wiring.
    final showArtwork = context.watch<ThemeController>().showArtwork;
    final accent = theme.colorScheme.primary;
    final radius = borderRadius ?? BorderRadius.circular(size / 8);

    final placeholder = _ArtworkPlaceholder(
      size: size,
      radius: radius,
      iconSize: placeholderIconSize ?? size * 0.45,
      icon: fallbackIcon,
      color: accent,
    );

    final path = track.artworkPath;
    if (!showArtwork || path == null || path.isEmpty) {
      return _wrap(placeholder, radius);
    }

    return _wrap(
      Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Matches the placeholder fallback so a missing file gives the
        // exact same visual instead of a broken-image glyph.
        errorBuilder: (_, __, ___) => placeholder,
        // Use the bounded cache size so large maxres thumbnails don't
        // hold full-resolution bitmaps in memory for tiny list-tile
        // renders. Multiplying by 2 gives crispness on hi-DPI screens.
        cacheWidth: (size * 2).round(),
        cacheHeight: (size * 2).round(),
      ),
      radius,
    );
  }

  Widget _wrap(Widget child, BorderRadius radius) {
    if (elevation == 0) {
      return ClipRRect(borderRadius: radius, child: child);
    }
    return PhysicalModel(
      color: Colors.transparent,
      borderRadius: radius,
      elevation: elevation,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder({
    required this.size,
    required this.radius,
    required this.iconSize,
    required this.icon,
    required this.color,
  });

  final double size;
  final BorderRadius radius;
  final double iconSize;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: radius,
      ),
      child: Icon(
        icon,
        color: color,
        size: iconSize,
      ),
    );
  }
}
