import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/track_model.dart';
import '../../services/audio_player_service.dart';
import '../screens/player_screen.dart';

/// Fixed 70px mini-player bar for mobile with skip controls.
///
/// Uses [AudioPlayerService.currentTrackStream] so the title/artist
/// repaint immediately when the user (or the engine) moves to the next /
/// previous track, instead of one frame after the engine's index actually
/// flips. We also still subscribe to [AudioPlayerService] via
/// `context.watch` so the bar disappears once the queue is empty.
class MobileMiniPlayer extends StatelessWidget {
  /// Creates the mini player.
  const MobileMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final audioService = context.watch<AudioPlayerService>();
    final accentColor = Theme.of(context).colorScheme.primary;

    return StreamBuilder<TrackModel?>(
      stream: audioService.currentTrackStream,
      // Seed with the synchronous getter so the first frame after a route
      // pop also paints with the right title (the stream's first event
      // arrives one tick later).
      initialData: audioService.currentTrack,
      builder: (context, snapshot) {
        final track = snapshot.data ?? audioService.currentTrack;
        if (track == null) return const SizedBox.shrink();

        return GestureDetector(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerScreen()),
            );
          },
          child: Container(
            height: 70,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                ),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                // Album art placeholder
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.music_note,
                    color: accentColor,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 12),

                // Track info (with overflow protection)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        track.displayArtistLabel,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.6),
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // Media controls
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Shuffle toggle — tints to the accent color when
                    // active so the user can see at a glance whether
                    // the queue order is being randomized. Tap is
                    // consumed locally so it doesn't bubble up to the
                    // parent GestureDetector and open the full player.
                    SizedBox(
                      width: 40,
                      height: 48,
                      child: IconButton(
                        tooltip: audioService.shuffleEnabled
                            ? 'Shuffle: ON'
                            : 'Shuffle: OFF',
                        icon: const Icon(Icons.shuffle),
                        iconSize: 22,
                        padding: EdgeInsets.zero,
                        color: audioService.shuffleEnabled
                            ? accentColor
                            : Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.5),
                        onPressed: () => audioService.toggleShuffle(),
                      ),
                    ),

                    // Previous button
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: IconButton(
                        icon: const Icon(Icons.skip_previous),
                        iconSize: 28,
                        color: accentColor,
                        onPressed: () => audioService.skipPrevious(),
                      ),
                    ),

                    // Play/Pause button
                    StreamBuilder<bool>(
                      stream: audioService.playingStream,
                      builder: (context, snapshot) {
                        final isPlaying = snapshot.data ?? false;
                        return SizedBox(
                          width: 48,
                          height: 48,
                          child: IconButton(
                            icon: Icon(
                              isPlaying ? Icons.pause : Icons.play_arrow,
                              size: 32,
                            ),
                            color: accentColor,
                            onPressed: () {
                              if (isPlaying) {
                                audioService.pause();
                              } else {
                                audioService.play();
                              }
                            },
                          ),
                        );
                      },
                    ),

                    // Next button
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: IconButton(
                        icon: const Icon(Icons.skip_next),
                        iconSize: 28,
                        color: accentColor,
                        onPressed: () => audioService.skipNext(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
