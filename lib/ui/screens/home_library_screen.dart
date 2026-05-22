import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database_helper.dart';
import '../../models/track_model.dart';
import '../../services/library_service.dart';
import '../widgets/import_modal.dart';
import '../widgets/library_search_field.dart';
import '../widgets/track_tile.dart';
import 'playlist_detail_screen.dart';

/// Main library screen with Tracks/Playlists segmented control.
class HomeLibraryScreen extends StatefulWidget {
  const HomeLibraryScreen({super.key, this.onOpenPlaylist});

  /// Optional callback invoked when the user opens a playlist from the
  /// "Playlists" tab. When provided (desktop shell), the host swaps its
  /// body to render [PlaylistDetailScreen] inside its own scaffold so the
  /// persistent [GlassPlayerBar] stays visible — exactly the same path
  /// the sidebar uses.
  final ValueChanged<int>? onOpenPlaylist;

  @override
  State<HomeLibraryScreen> createState() => _HomeLibraryScreenState();
}

class _HomeLibraryScreenState extends State<HomeLibraryScreen> {
  int _selectedSegment = 0; // 0 = Tracks, 1 = Playlists

  /// Drives the live search field. Persists across rebuilds so the
  /// query survives Provider notifications.
  final TextEditingController _searchCtrl = TextEditingController();

  /// Lowercased trimmed copy of [_searchCtrl.text] cached on every
  /// keystroke. Compared against the lowercased title / artist of each
  /// track so the filter is case-insensitive without re-lowercasing on
  /// every list element.
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Filters [tracks] by the current search query (title + artist,
  /// case-insensitive substring match). Returns the original list when
  /// the search box is empty, matching the "show everything by
  /// default" UX requirement.
  List<TrackModel> _filteredTracks(List<TrackModel> tracks) {
    if (_searchQuery.isEmpty) return tracks;
    return tracks.where((t) {
      final title = t.title.toLowerCase();
      final artist = t.displayArtistLabel.toLowerCase();
      return title.contains(_searchQuery) || artist.contains(_searchQuery);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryService>();
    final allTracks = lib.tracks;
    final tracks = _filteredTracks(allTracks);
    final playlists = lib.playlists;
    final showingTracks = _selectedSegment == 0;

    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Your library',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () => _selectedSegment == 0
                            ? showPlamusImportDialog(context)
                            : _showCreatePlaylistDialog(context, lib),
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 16),
                        ),
                        icon: const Icon(Icons.add),
                        label:
                            Text(_selectedSegment == 0 ? 'Import' : 'Playlist'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Segmented control
                  Container(
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _SegmentButton(
                            label: 'Tracks',
                            isSelected: _selectedSegment == 0,
                            onTap: () => setState(() => _selectedSegment = 0),
                          ),
                        ),
                        Expanded(
                          child: _SegmentButton(
                            label: 'Playlists',
                            isSelected: _selectedSegment == 1,
                            onTap: () => setState(() => _selectedSegment = 1),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Live search field — only shown when the library has
                  // tracks to filter (no point rendering it for an
                  // empty library, and it would push the empty-state
                  // message further down for no reason). Hidden when
                  // the user is browsing playlists; playlists are
                  // first-class containers and the requirement only
                  // asks for track-search in the library + per-playlist
                  // screens.
                  if (showingTracks && allTracks.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    LibrarySearchField(
                      controller: _searchCtrl,
                      onChanged: (value) {
                        final normalized = value.trim().toLowerCase();
                        if (normalized == _searchQuery) return;
                        setState(() => _searchQuery = normalized);
                      },
                      hintText: 'Search tracks',
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Content based on selected segment
          if (showingTracks) ...[
            // Tracks view
            if (allTracks.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    'No tracks yet. Import files or paste a YouTube link.',
                    style: Theme.of(context).textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (tracks.isEmpty)
              // Library has tracks, but none match the search filter.
              // Keep the search field interactive (no full-screen
              // takeover) by using a small inline message instead of a
              // SliverFillRemaining empty state.
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 48, 32, 48),
                  child: Center(
                    child: Text(
                      'No tracks match "${_searchCtrl.text}".',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                  (context, i) {
                    final t = tracks[i];
                    return TrackTile(
                      track: t,
                      // Use the FILTERED list as the playback context
                      // so "play" / next / previous walk through the
                      // currently-visible rows in the same order the
                      // user sees them.
                      contextTracks: tracks,
                      contextId: 'library',
                      onRenamed: () => lib.refreshTracks(),
                    );
                  },
                  childCount: tracks.length,
                ),
              ),
          ] else ...[
            // Playlists view
            if (playlists.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    'No playlists yet. Tap + to create one.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final playlist = playlists[i];
                      return FutureBuilder<List<dynamic>>(
                        future: DatabaseHelper.instance
                            .getTracksForPlaylist(playlist.id!),
                        builder: (context, snapshot) {
                          final trackCount = snapshot.data?.length ?? 0;
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            child: ListTile(
                              leading: Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.queue_music,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              title: Text(
                                playlist.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text('$trackCount tracks'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                // Unified navigation (BUG FIX): when
                                // the host (desktop shell) provides a
                                // callback, route through its state so
                                // the playlist renders inside the
                                // shell — same path the sidebar uses,
                                // keeping the persistent
                                // GlassPlayerBar visible and the
                                // now-playing context scoped to the
                                // playlist surface.
                                final cb = widget.onOpenPlaylist;
                                if (cb != null) {
                                  cb(playlist.id!);
                                } else {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => PlaylistDetailScreen(
                                        playlistId: playlist.id!,
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                          );
                        },
                      );
                    },
                    childCount: playlists.length,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _showCreatePlaylistDialog(BuildContext context, LibraryService lib) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Create playlist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Playlist name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  await lib.createPlaylist(name);
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }
}

class _SegmentButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SegmentButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isSelected
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}


