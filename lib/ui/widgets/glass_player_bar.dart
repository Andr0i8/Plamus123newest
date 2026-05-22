import 'dart:ui';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import '../../models/repeat_mode.dart';
import '../../models/track_model.dart';
import '../../services/audio_player_service.dart';
import '../theme/theme_controller.dart';
import 'sleep_timer_button.dart';
import 'track_artwork.dart';

/// Professional bottom glass-style transport bar with SUBTLE polish.
/// Hover: 1.05x scale, 150ms duration, NO glow effects.
class GlassPlayerBar extends StatefulWidget {
  const GlassPlayerBar({super.key});

  @override
  State<GlassPlayerBar> createState() => _GlassPlayerBarState();
}

class _GlassPlayerBarState extends State<GlassPlayerBar> {
  bool _isSeeking = false;
  double _seekPosition = 0.0;
  bool _isPlayHovered = false;
  bool _isPrevHovered = false;
  bool _isNextHovered = false;
  bool _isRepeatHovered = false;
  bool _isShuffleHovered = false;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$m:$s';
    }
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final audio = context.watch<AudioPlayerService>();
    final primary = theme.colorScheme.primary;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? Colors.black.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.3),
                  width: 1.5,
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: StreamBuilder<TrackModel?>(
                stream: audio.currentTrackStream,
                builder: (context, trackSnapshot) {
                  final track = trackSnapshot.data;

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Progress slider with subtle hover
                      StreamBuilder<Duration>(
                        stream: audio.positionStream,
                        builder: (context, positionSnapshot) {
                          return StreamBuilder<Duration?>(
                            stream: audio.durationStream,
                            builder: (context, durationSnapshot) {
                              final position =
                                  positionSnapshot.data ?? Duration.zero;
                              final duration =
                                  durationSnapshot.data ?? Duration.zero;
                              final progress = duration.inMilliseconds > 0
                                  ? position.inMilliseconds /
                                      duration.inMilliseconds
                                  : 0.0;

                              return Column(
                                children: [
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 4.0,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 7.0,
                                      ),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                        overlayRadius: 16.0,
                                      ),
                                      activeTrackColor: primary,
                                      inactiveTrackColor: theme.dividerColor
                                          .withValues(alpha: 0.3),
                                      thumbColor: primary,
                                      overlayColor:
                                          primary.withValues(alpha: 0.2),
                                    ),
                                    child: Slider(
                                      value: _isSeeking
                                          ? _seekPosition
                                          : progress.clamp(0.0, 1.0),
                                      onChanged:
                                          track == null || audio.isLoading
                                              ? null
                                              : (value) {
                                                  setState(() {
                                                    _isSeeking = true;
                                                    _seekPosition = value;
                                                  });
                                                },
                                      onChangeEnd: (value) async {
                                        if (track != null && !audio.isLoading) {
                                          final seekTo = Duration(
                                            milliseconds: (value *
                                                    duration.inMilliseconds)
                                                .round(),
                                          );
                                          await audio.seek(seekTo);
                                        }
                                        setState(() {
                                          _isSeeking = false;
                                        });
                                      },
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _fmt(position),
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: theme
                                                .textTheme.bodySmall?.color
                                                ?.withValues(alpha: 0.8),
                                          ),
                                        ),
                                        Text(
                                          _fmt(duration),
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: theme
                                                .textTheme.bodySmall?.color
                                                ?.withValues(alpha: 0.8),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      // Main control row
                      Row(
                        children: [
                          // Cover artwork — only rendered when the user
                          // has the "Show track artwork" preference on
                          // and a track is loaded. Hidden when artwork
                          // is disabled so the player bar collapses
                          // back to its pre-artwork layout, matching
                          // the request: "When off, everything looks
                          // exactly like before".
                          if (track != null &&
                              context.watch<ThemeController>().showArtwork) ...[
                            TrackArtwork(
                              track: track,
                              size: 44,
                              borderRadius: BorderRadius.circular(8),
                              placeholderIconSize: 22,
                              elevation: 4,
                            ),
                            const SizedBox(width: 12),
                          ],
                          // Track info
                          Expanded(
                            flex: 3,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  track?.title ?? 'Nothing playing',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  track == null
                                      ? '—'
                                      : track.displayArtistLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.textTheme.bodySmall?.color
                                        ?.withValues(alpha: 0.65),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Centered playback controls with subtle hover
                          StreamBuilder<bool>(
                            stream: audio.playingStream,
                            builder: (context, playingSnapshot) {
                              final playing = playingSnapshot.data ?? false;

                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Shuffle button (BUG 3) — mirrors the
                                  // repeat button's hover styling and
                                  // highlights when shuffle is active so
                                  // the user can see current state.
                                  MouseRegion(
                                    onEnter: (_) => setState(
                                        () => _isShuffleHovered = true),
                                    onExit: (_) => setState(
                                        () => _isShuffleHovered = false),
                                    child: AnimatedScale(
                                      scale: _isShuffleHovered ? 1.05 : 1.0,
                                      duration:
                                          const Duration(milliseconds: 150),
                                      curve: Curves.easeOut,
                                      child: IconButton(
                                        iconSize: 20,
                                        constraints: const BoxConstraints(
                                            minWidth: 40, minHeight: 40),
                                        padding: EdgeInsets.zero,
                                        tooltip: audio.shuffleEnabled
                                            ? 'Shuffle: ON'
                                            : 'Shuffle: OFF',
                                        icon: Icon(
                                          Icons.shuffle,
                                          size: 20,
                                          color: audio.shuffleEnabled
                                              ? primary
                                              : (theme.iconTheme.color ??
                                                      Colors.white)
                                                  .withValues(alpha: 0.4),
                                        ),
                                        onPressed:
                                            track == null || audio.isLoading
                                                ? null
                                                : () => audio.toggleShuffle(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  // Repeat button
                                  MouseRegion(
                                    onEnter: (_) =>
                                        setState(() => _isRepeatHovered = true),
                                    onExit: (_) => setState(
                                        () => _isRepeatHovered = false),
                                    child: AnimatedScale(
                                      scale: _isRepeatHovered ? 1.05 : 1.0,
                                      duration:
                                          const Duration(milliseconds: 150),
                                      curve: Curves.easeOut,
                                      child: IconButton(
                                        iconSize: 20,
                                        constraints: const BoxConstraints(
                                            minWidth: 40, minHeight: 40),
                                        padding: EdgeInsets.zero,
                                        tooltip: _repeatTooltip(
                                            audio.currentRepeatMode),
                                        icon: _repeatModeIcon(
                                            audio.currentRepeatMode,
                                            primary,
                                            theme),
                                        onPressed:
                                            track == null || audio.isLoading
                                                ? null
                                                : () => audio.cycleRepeatMode(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  // Previous button
                                  MouseRegion(
                                    onEnter: (_) =>
                                        setState(() => _isPrevHovered = true),
                                    onExit: (_) =>
                                        setState(() => _isPrevHovered = false),
                                    child: AnimatedScale(
                                      scale: _isPrevHovered ? 1.05 : 1.0,
                                      duration:
                                          const Duration(milliseconds: 150),
                                      curve: Curves.easeOut,
                                      child: IconButton(
                                        iconSize: 22,
                                        constraints: const BoxConstraints(
                                            minWidth: 40, minHeight: 40),
                                        padding: EdgeInsets.zero,
                                        tooltip: 'Previous',
                                        icon: const Icon(
                                            FontAwesomeIcons.backwardStep),
                                        onPressed:
                                            track == null || audio.isLoading
                                                ? null
                                                : () => audio.skipPrevious(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // Play/Pause button
                                  MouseRegion(
                                    onEnter: (_) =>
                                        setState(() => _isPlayHovered = true),
                                    onExit: (_) =>
                                        setState(() => _isPlayHovered = false),
                                    child: AnimatedScale(
                                      scale: _isPlayHovered ? 1.05 : 1.0,
                                      duration:
                                          const Duration(milliseconds: 150),
                                      curve: Curves.easeOut,
                                      child: FilledButton(
                                        style: FilledButton.styleFrom(
                                          shape: const CircleBorder(),
                                          padding: const EdgeInsets.all(12),
                                          minimumSize: const Size(50, 50),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          backgroundColor: primary,
                                        ),
                                        onPressed:
                                            track == null || audio.isLoading
                                                ? null
                                                : () async {
                                                    if (playing) {
                                                      await audio.pause();
                                                    } else {
                                                      await audio.play();
                                                    }
                                                  },
                                        child: Icon(
                                          playing
                                              ? FontAwesomeIcons.pause
                                              : FontAwesomeIcons.play,
                                          size: 18,
                                          color: theme.colorScheme.onPrimary,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // Next button
                                  MouseRegion(
                                    onEnter: (_) =>
                                        setState(() => _isNextHovered = true),
                                    onExit: (_) =>
                                        setState(() => _isNextHovered = false),
                                    child: AnimatedScale(
                                      scale: _isNextHovered ? 1.05 : 1.0,
                                      duration:
                                          const Duration(milliseconds: 150),
                                      curve: Curves.easeOut,
                                      child: IconButton(
                                        iconSize: 22,
                                        constraints: const BoxConstraints(
                                            minWidth: 40, minHeight: 40),
                                        padding: EdgeInsets.zero,
                                        tooltip: 'Next',
                                        icon: const Icon(
                                            FontAwesomeIcons.forwardStep),
                                        onPressed:
                                            track == null || audio.isLoading
                                                ? null
                                                : () => audio.skipNext(),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          const SleepTimerButton(iconSize: 20),
                          const SizedBox(width: 16),
                          // Enhanced volume control
                          Expanded(
                            flex: 2,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Icon(
                                  _volumeIcon(audio.volume),
                                  size: 20,
                                  color: theme.iconTheme.color
                                      ?.withValues(alpha: 0.75),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 120,
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3.5,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 6.0,
                                      ),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                        overlayRadius: 14.0,
                                      ),
                                    ),
                                    child: Slider(
                                      value: audio.volume,
                                      onChanged: audio.isLoading
                                          ? null
                                          : (v) {
                                              audio.setVolumeLinear(v);
                                            },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  IconData _volumeIcon(double volume) {
    if (volume == 0) return FontAwesomeIcons.volumeXmark;
    if (volume < 0.5) return FontAwesomeIcons.volumeLow;
    return FontAwesomeIcons.volumeHigh;
  }

  String _repeatTooltip(RepeatMode m) {
    return switch (m) {
      RepeatMode.off => 'Repeat: OFF (stops after track)',
      RepeatMode.all => 'Repeat: ALL (loops queue)',
      RepeatMode.one => 'Repeat: ONE (loops track)',
    };
  }

  Widget _repeatModeIcon(RepeatMode m, Color primary, ThemeData theme) {
    final base = theme.iconTheme.color ?? Colors.white;
    return switch (m) {
      RepeatMode.off => Icon(
          Icons.repeat,
          size: 20,
          color: base.withValues(alpha: 0.4),
        ),
      RepeatMode.all => Icon(
          Icons.repeat,
          size: 20,
          color: primary,
        ),
      RepeatMode.one => Icon(
          Icons.repeat_one,
          size: 20,
          color: primary,
        ),
    };
  }
}
