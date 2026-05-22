import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import '../../database/database_helper.dart';
import '../../models/history_entry.dart';
import '../../models/track_model.dart';
import '../../services/audio_player_service.dart';
import '../../services/library_service.dart';
import '../theme/theme_controller.dart';
import '../widgets/track_artwork.dart';

/// Chronological “Recently played” smart list (up to 50 DB rows).
class HistoryScreen extends StatefulWidget {
  /// Creates the history screen.
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static String _formatPlayedAt(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  late Future<List<HistoryEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = DatabaseHelper.instance.getRecentHistory(limit: 50);
  }

  Future<void> _reload() async {
    setState(() {
      _future = DatabaseHelper.instance.getRecentHistory(limit: 50);
    });
    await _future;
  }

  Future<void> _clearAllHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text(
          'This will remove all play history. Your tracks will remain in the library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;

    try {
      await DatabaseHelper.instance.clearHistory();
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('History cleared')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to clear history: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.read<LibraryService>();
    final audio = context.read<AudioPlayerService>();

    return Scaffold(
      body: FutureBuilder<List<HistoryEntry>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snap.data!;
          final tracks = entries.map((e) => e.track).toList();

          return CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
                  child: Row(
                    children: [
                      Text(
                        'History',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const Spacer(),
                      if (tracks.isNotEmpty) ...[
                        OutlinedButton.icon(
                          onPressed: _clearAllHistory,
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 14),
                          ),
                          icon: const Icon(Icons.clear_all, size: 18),
                          label: const Text('Clear all'),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () async {
                            await audio.setQueue(
                              tracks,
                              playImmediately: true,
                              contextId: 'history',
                            );
                          },
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 16),
                          ),
                          child: const Text('Play all'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (entries.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child:
                      Center(child: Text('Play something to build history.')),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final e = entries[i];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                                left: 24, top: 12, bottom: 4),
                            child: Text(
                              _formatPlayedAt(e.playedAt),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                          _HistoryTrackTile(
                            track: e.track,
                            contextTracks: tracks,
                            onChanged: () {
                              lib.refreshTracks();
                              _reload();
                            },
                          ),
                        ],
                      );
                    },
                    childCount: entries.length,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Custom track tile for history screen with "Remove from history" option.
class _HistoryTrackTile extends StatefulWidget {
  const _HistoryTrackTile({
    required this.track,
    required this.onChanged,
    this.contextTracks,
  });

  final TrackModel track;
  final VoidCallback onChanged;
  final List<TrackModel>? contextTracks;

  @override
  State<_HistoryTrackTile> createState() => _HistoryTrackTileState();
}

class _HistoryTrackTileState extends State<_HistoryTrackTile> {
  bool _hover = false;
  bool _editing = false;
  late final TextEditingController _titleCtrl =
      TextEditingController(text: widget.track.title);

  @override
  void didUpdateWidget(covariant _HistoryTrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && oldWidget.track.title != widget.track.title) {
      _titleCtrl.text = widget.track.title;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  String _formatDuration(int ms) {
    if (ms <= 0) return '—';
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:$s';
    }
    return '$m:$s';
  }

  Future<void> _addToPlaylist() async {
    final lib = context.read<LibraryService>();
    await lib.refreshAll();
    final playlists = lib.playlists;
    if (!mounted) return;
    if (playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Create a playlist first from the sidebar.'),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: playlists.map((p) {
              return ListTile(
                title: Text(p.name),
                onTap: () async {
                  if (p.id != null && widget.track.id != null) {
                    await lib.addTrackToPlaylist(p.id!, widget.track.id!);
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Added to playlist')),
                    );
                  }
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Future<void> _shareTrackLink() async {
    final url = widget.track.shareableSourceUrl;
    if (url == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No link available for this track')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied')),
    );
  }

  Future<void> _commitTitle() async {
    final lib = context.read<LibraryService>();
    try {
      await lib.renameTrackTitle(widget.track, _titleCtrl.text);
      if (!mounted) return;
      setState(() => _editing = false);
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not rename: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final audio = context.watch<AudioPlayerService>();
    final lib = context.read<LibraryService>();
    // See `track_tile.dart` — same rationale: watch ThemeController so
    // the leading column rebuilds when the user toggles "Show track
    // artwork" without touching every parent screen.
    final showArtwork = context.watch<ThemeController>().showArtwork;

    // Check if this track is currently playing AND was started from the
    // history surface. Tracks playing from the library / liked / a
    // playlist should not light up here (BUG 8).
    final currentTrack = audio.currentTrack;
    final sameId =
        currentTrack?.id != null && currentTrack?.id == widget.track.id;
    final sameContext =
        audio.playbackContextId == null || audio.playbackContextId == 'history';
    final isPlaying = sameId && sameContext;
    final accentColor = theme.colorScheme.primary;

    // Get context tracks for queue building
    final contextTracks = widget.contextTracks ?? [widget.track];

    final heart = IconButton(
      tooltip: widget.track.isLiked ? 'Unlike' : 'Like',
      icon: Icon(
        widget.track.isLiked ? Icons.favorite : Icons.favorite_border,
        color: widget.track.isLiked ? theme.colorScheme.primary : null,
        size: 22,
      ),
      onPressed: () async {
        await lib.toggleLike(widget.track);
        widget.onChanged();
      },
    );
    final Widget leading = showArtwork
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TrackArtwork(track: widget.track, size: 48),
              const SizedBox(width: 8),
              heart,
            ],
          )
        : heart;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? 1.01 : 1.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          decoration: BoxDecoration(
            color: isPlaying
                ? accentColor.withValues(alpha: 0.12)
                : _hover
                    ? theme.colorScheme.primary.withValues(alpha: 0.06)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: leading,
            title: Row(
              children: [
                Expanded(
                  child: _editing
                      ? TextField(
                          controller: _titleCtrl,
                          autofocus: true,
                          decoration: const InputDecoration(isDense: true),
                          onSubmitted: (_) => _commitTitle(),
                        )
                      : GestureDetector(
                          onTap: () => setState(() {
                            _editing = true;
                            _titleCtrl
                              ..text = widget.track.title
                              ..selection = TextSelection(
                                baseOffset: 0,
                                extentOffset: widget.track.title.length,
                              );
                          }),
                          child: Text(
                            widget.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: isPlaying ? accentColor : null,
                              fontWeight: isPlaying ? FontWeight.w600 : null,
                            ),
                          ),
                        ),
                ),
                if (isPlaying && audio.playing)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _AnimatedMusicBars(color: accentColor),
                  ),
              ],
            ),
            subtitle: Text(
              '${widget.track.displayArtistLabel} · ${_formatDuration(widget.track.durationMs)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip:
                      isPlaying ? (audio.playing ? 'Pause' : 'Resume') : 'Play',
                  icon: FaIcon(
                    isPlaying && audio.playing
                        ? FontAwesomeIcons.pause
                        : FontAwesomeIcons.play,
                    size: 18,
                  ),
                  onPressed: () async {
                    await audio.togglePlayTrack(
                      widget.track,
                      contextTracks,
                      contextId: 'history',
                    );
                  },
                ),
                PopupMenuButton<String>(
                  onSelected: (value) async {
                    try {
                      if (value == 'playlist') {
                        await _addToPlaylist();
                      } else if (value == 'folder') {
                        await lib.revealTrackInExplorer(widget.track);
                      } else if (value == 'export') {
                        await lib.exportTrackTo(widget.track);
                      } else if (value == 'share') {
                        await _shareTrackLink();
                      } else if (value == 'remove_history') {
                        if (widget.track.id != null) {
                          await DatabaseHelper.instance
                              .removeTrackFromHistory(widget.track.id!);
                          widget.onChanged();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Removed from history'),
                            ),
                          );
                        }
                      } else if (value == 'delete') {
                        await lib.deleteTrack(widget.track);
                        widget.onChanged();
                      }
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e')),
                      );
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'playlist',
                      child: Text('Add to playlist…'),
                    ),
                    const PopupMenuItem(
                      value: 'folder',
                      child: Text('Show in folder'),
                    ),
                    const PopupMenuItem(
                      value: 'export',
                      child: Text('Export to…'),
                    ),
                    if (widget.track.shareableSourceUrl != null)
                      const PopupMenuItem(
                        value: 'share',
                        child: Text('Share'),
                      ),
                    const PopupMenuItem(
                      value: 'remove_history',
                      child: Text('Remove from history'),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Remove from library'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Animated music visualizer bars for "now playing" indicator.
class _AnimatedMusicBars extends StatefulWidget {
  const _AnimatedMusicBars({required this.color});

  final Color color;

  @override
  State<_AnimatedMusicBars> createState() => _AnimatedMusicBarsState();
}

class _AnimatedMusicBarsState extends State<_AnimatedMusicBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 16,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _Bar(
                height: 4 + (_controller.value * 8),
                color: widget.color,
              ),
              _Bar(
                height: 8 + ((1 - _controller.value) * 6),
                color: widget.color,
              ),
              _Bar(
                height: 6 + (_controller.value * 7),
                color: widget.color,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
