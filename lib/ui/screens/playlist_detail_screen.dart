import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database_helper.dart';
import '../../models/playlist_model.dart';
import '../../models/track_model.dart';
import '../../services/audio_player_service.dart';
import '../../services/library_service.dart';
import '../widgets/glass_player_bar.dart';
import '../widgets/import_panel.dart';
import '../widgets/library_search_field.dart';
import '../widgets/track_artwork.dart';
import '../widgets/track_tile.dart';

/// Single user playlist: lists ordered tracks and can play the whole queue.
///
/// Renders its own back arrow + "+" action in the AppBar so users can
/// get out of the screen and add tracks without going back to the
/// library. The shell's persistent `GlassPlayerBar` is shown below.
class PlaylistDetailScreen extends StatefulWidget {
  /// Creates a playlist screen for the given [playlistId].
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final int playlistId;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late Future<PlaylistModel?> _meta;
  late Future<List<TrackModel>> _tracks;

  /// String key used by [AudioPlayerService] to scope the "now playing"
  /// highlight to this specific playlist (BUG 8). Stable per route.
  late final String _contextId = 'playlist:${widget.playlistId}';

  /// Drives the in-playlist search field. Owned by the state so its
  /// content survives `_reload()` after track additions / removals.
  final TextEditingController _searchCtrl = TextEditingController();

  /// Lowercased + trimmed copy of [_searchCtrl.text] used by the
  /// case-insensitive title / artist filter. Cached so we don't
  /// lowercase the query for every track on every keystroke.
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    _meta = DatabaseHelper.instance.getPlaylistById(widget.playlistId);
    _tracks = DatabaseHelper.instance.getTracksForPlaylist(widget.playlistId);
  }

  /// Filters [tracks] by the current search query (title + artist,
  /// case-insensitive substring match). Returns the original list when
  /// the search box is empty.
  List<TrackModel> _filteredTracks(List<TrackModel> tracks) {
    if (_searchQuery.isEmpty) return tracks;
    return tracks.where((t) {
      final title = t.title.toLowerCase();
      final artist = t.displayArtistLabel.toLowerCase();
      return title.contains(_searchQuery) || artist.contains(_searchQuery);
    }).toList(growable: false);
  }

  /// Opens the "+" action sheet: pick between adding from the existing
  /// library or importing a new file / URL directly into this playlist.
  Future<void> _showAddTrackOptions() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.library_music),
                title: const Text('Add from library'),
                subtitle: const Text(
                  'Pick existing tracks from your main library',
                ),
                onTap: () => Navigator.of(ctx).pop('from_library'),
              ),
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Import new track'),
                subtitle: const Text(
                  "Download a YouTube link or browse files; the track is "
                  'added ONLY to this playlist',
                ),
                onTap: () => Navigator.of(ctx).pop('import_new'),
              ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    switch (choice) {
      case 'from_library':
        await _pickFromLibrary();
        break;
      case 'import_new':
        await _importNew();
        break;
    }
  }

  /// Bottom sheet listing every track currently in the main library.
  /// Selected rows get linked into this playlist via
  /// [LibraryService.addTrackToPlaylist].
  Future<void> _pickFromLibrary() async {
    final lib = context.read<LibraryService>();
    await lib.refreshAll();
    if (!mounted) return;

    final libraryTracks = lib.tracks;
    if (libraryTracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your library is empty.')),
      );
      return;
    }

    // Exclude tracks already in the playlist so the user isn't presented
    // with no-op options.
    final currentTracks = await _tracks;
    final existingIds = currentTracks.map((t) => t.id).toSet();
    final candidates =
        libraryTracks.where((t) => !existingIds.contains(t.id)).toList();

    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('All your library tracks are already in this playlist.'),
        ),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.75,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Text(
                    'Add tracks to playlist',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: candidates.length,
                    itemBuilder: (_, i) {
                      final t = candidates[i];
                      return ListTile(
                        // [TrackArtwork] reads the same "Show track
                        // artwork" preference used elsewhere, so this
                        // picker stays consistent with the rest of the
                        // library and falls back to the music-note
                        // placeholder when artwork is disabled or
                        // missing.
                        leading: TrackArtwork(track: t, size: 44),
                        title: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          t.displayArtistLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.add),
                        onTap: () async {
                          if (t.id == null) return;
                          await lib.addTrackToPlaylist(
                            widget.playlistId,
                            t.id!,
                          );
                          if (ctx.mounted) Navigator.of(ctx).pop();
                          if (mounted) {
                            setState(_reload);
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Shows the shared [ImportPanel] in playlist-only mode: imported tracks
  /// are saved with `inLibrary = 0` (BUG 6) and immediately linked into
  /// this playlist via [LibraryService.addTrackToPlaylist]. The result is
  /// a track that's ONLY reachable from this playlist — it doesn't show
  /// up in the main library.
  Future<void> _importNew() async {
    final lib = context.read<LibraryService>();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Import to this playlist',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                ImportPanel(
                  addToLibrary: false,
                  onTrackImported: (trackId) async {
                    await lib.addTrackToPlaylist(widget.playlistId, trackId);
                    if (mounted) setState(_reload);
                  },
                  onDone: () {
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _removeFromPlaylist(TrackModel track) async {
    if (track.id == null) return;
    final lib = context.read<LibraryService>();
    await lib.removeTrackFromPlaylist(widget.playlistId, track.id!);
    if (!mounted) return;
    setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.read<LibraryService>();
    final audio = context.read<AudioPlayerService>();
    // The shell uses state-based navigation, so there's nothing to pop
    // when embedded inside it (omit the back arrow). When pushed as a
    // route, render our own back arrow plus a defensive
    // [GlassPlayerBar] so the bottom player never disappears.
    final canPop = Navigator.of(context).canPop();

    return FutureBuilder<PlaylistModel?>(
      future: _meta,
      builder: (context, metaSnap) {
        final name = metaSnap.data?.name ?? 'Playlist';
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: canPop,
            leading: canPop ? const BackButton() : null,
            title: Text(name),
            actions: [
              IconButton(
                tooltip: 'Add track',
                icon: const Icon(Icons.add),
                onPressed: _showAddTrackOptions,
              ),
            ],
          ),
          // Embedded in shell (canPop == false) → null: the shell
          // renders its own [GlassPlayerBar] below the body. Pushed as
          // a route → render one here so the player stays visible.
          bottomNavigationBar:
              canPop ? const GlassPlayerBar() : null,
          body: FutureBuilder<List<TrackModel>>(
            future: _tracks,
            builder: (context, trackSnap) {
              if (!trackSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final allTracks = trackSnap.data!;
              final filteredTracks = _filteredTracks(allTracks);

              return CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  name,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              if (allTracks.isNotEmpty)
                                FilledButton(
                                  // Play whatever the user currently
                                  // sees: when the search filter is
                                  // active, "Play all" plays the
                                  // visible subset rather than the
                                  // whole playlist, so the queue
                                  // matches what's on screen.
                                  onPressed: filteredTracks.isEmpty
                                      ? null
                                      : () async {
                                          await audio.setQueue(
                                            filteredTracks,
                                            playImmediately: true,
                                            contextId: _contextId,
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
                          ),
                          // Live search field — only rendered when the
                          // playlist actually has tracks to filter, so
                          // a freshly-created empty playlist keeps the
                          // big "Add a track" call-to-action front and
                          // centre.
                          if (allTracks.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            LibrarySearchField(
                              controller: _searchCtrl,
                              onChanged: (value) {
                                final normalized =
                                    value.trim().toLowerCase();
                                if (normalized == _searchQuery) return;
                                setState(() => _searchQuery = normalized);
                              },
                              hintText: 'Search tracks in this playlist',
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (allTracks.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('No tracks yet.'),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: _showAddTrackOptions,
                                icon: const Icon(Icons.add),
                                label: const Text('Add a track'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else if (filteredTracks.isEmpty)
                    // Playlist has tracks but none match the active
                    // search filter. Keep the search field interactive
                    // (no SliverFillRemaining take-over) so the user
                    // can keep typing or clear the query.
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(32, 48, 32, 48),
                        child: Center(
                          child: Text(
                            'No tracks match "${_searchCtrl.text}".',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.7),
                                ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => TrackTile(
                          track: filteredTracks[i],
                          // Play context follows what's visible —
                          // skipping next/previous walks the filtered
                          // subset, matching the "Play all" behaviour
                          // above.
                          contextTracks: filteredTracks,
                          contextId: _contextId,
                          onRenamed: () {
                            lib.refreshAll();
                            setState(_reload);
                          },
                          onRemoveFromPlaylist: () =>
                              _removeFromPlaylist(filteredTracks[i]),
                        ),
                        childCount: filteredTracks.length,
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
