import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/playlist_model.dart';
import '../../services/library_service.dart';
import '../../services/plamus_paths.dart';
import '../../services/track_download_helper.dart';
import '../../services/youtube_playlist_service.dart';
import '../widgets/glass_player_bar.dart';

/// Per-track download status used to drive the row state badge in the
/// playlist preview screen.
enum _TrackStatus { pending, downloading, done, failed }

/// Where the downloaded tracks go. Controlled by the destination picker
/// above the "Download all" button.
enum _Destination {
  /// Create a new Plamus playlist whose name mirrors the YouTube
  /// playlist, and link every successfully-downloaded track into it.
  newPlaylist,

  /// Append every successfully-downloaded track to an existing Plamus
  /// playlist chosen from the user's library.
  existingPlaylist,

  /// No grouping: tracks are only registered in the main library.
  library,
}

/// Remote YouTube playlist preview.
///
/// Pushed as a route when the user taps a playlist row in the search
/// results (see `_ImportPanelState._onSearchResultTap`). The screen
///
///   1. fetches the full playlist via [YoutubePlaylistService],
///   2. shows its metadata (title, channel, total duration, track count),
///   3. lists every track with its individual duration,
///   4. offers a "Download all" action that downloads each track
///      sequentially using the same per-platform pipeline as the existing
///      single-track import flow ([TrackDownloadHelper]).
///
/// Each downloaded track is registered in the user's library via
/// [LibraryService.registerTrackFile]. The user picks one of three
/// destinations via the picker above the "Download all" button:
///
///   * **Create new playlist** ([_Destination.newPlaylist]) — creates a
///     new Plamus playlist whose name mirrors the YouTube playlist
///     title and links every track into it.
///   * **Add to existing playlist** ([_Destination.existingPlaylist]) —
///     appends every downloaded track to an already-existing Plamus
///     playlist chosen from a dropdown of the user's playlists.
///   * **Just add to library** ([_Destination.library]) — no playlist
///     is created; tracks only land in the main library.
class PlaylistPreviewScreen extends StatefulWidget {
  /// Creates a preview for [playlistId].
  ///
  /// [initialTitle] / [initialChannel] / [initialThumbnail] /
  /// [initialTrackCount] come from the search-result tile so we can paint
  /// a nice header immediately while the full track list loads in the
  /// background. They are overwritten with the server-reported values
  /// once the fetch completes.
  const PlaylistPreviewScreen({
    super.key,
    required this.playlistId,
    required this.playlistUrl,
    required this.initialTitle,
    required this.initialChannel,
    required this.initialThumbnail,
    required this.initialTrackCount,
  });

  final String playlistId;
  final String playlistUrl;
  final String initialTitle;
  final String initialChannel;
  final String initialThumbnail;
  final int initialTrackCount;

  @override
  State<PlaylistPreviewScreen> createState() => _PlaylistPreviewScreenState();
}

class _PlaylistPreviewScreenState extends State<PlaylistPreviewScreen> {
  late Future<YoutubePlaylistInfo> _future;

  /// Latest fetched payload. Cached so the UI doesn't have to re-resolve
  /// the future on every rebuild during the download phase.
  YoutubePlaylistInfo? _info;

  /// Per-track status indexed by track id. Updated as each download
  /// finishes / fails so the list rows show the right badge.
  final Map<String, _TrackStatus> _trackStatus = {};

  /// Fraction (0.0–1.0) of the currently-downloading track. Used by the
  /// per-row spinner so the user can see progress on a slow song.
  double _currentFraction = 0;

  /// True from "Download all" tap until the loop finishes or is cancelled.
  bool _downloading = false;

  /// True when the user cancelled mid-download. Stops the loop after the
  /// in-flight track finishes — we can't safely interrupt the actual
  /// HTTP / yt-dlp transfer mid-stream.
  bool _cancelled = false;

  /// Counters surfaced in the bottom status text. Both are post-incremented
  /// (only after the track actually finishes processing — either success
  /// via `registerTrackFile` or failure caught by the outer try / catch).
  /// The `_completed` count feeds the "Downloaded X of Y" summary and
  /// must therefore never include the in-flight track.
  int _completed = 0;
  int _failed = 0;

  /// User-controlled destination for the downloaded tracks. See
  /// [_Destination] for the semantics of each option. Defaults to
  /// [_Destination.newPlaylist] to preserve the historical behaviour
  /// where opening a playlist preview implies intent to keep the
  /// grouping.
  _Destination _destination = _Destination.newPlaylist;

  /// When [_destination] is [_Destination.existingPlaylist] this is the
  /// id the user explicitly picked from the dropdown. When `null`, or
  /// stale (the playlist was deleted elsewhere), [_effectiveExistingId]
  /// falls back to the first available playlist so the dropdown is
  /// never rendered with an invalid value.
  int? _selectedExistingPlaylistId;

  /// Resolves [_selectedExistingPlaylistId] against the live playlist
  /// list, returning the id that should actually be used when the
  /// destination is "existing playlist". Returns `null` only when the
  /// user has zero playlists.
  ///
  /// Pure derivation — does NOT mutate state, so it's safe to call
  /// from inside [build]. The user's explicit pick is preserved whenever
  /// it still refers to a real playlist; otherwise we fall through to
  /// the first playlist in the list.
  int? _effectiveExistingId(List<PlaylistModel> playlists) {
    if (playlists.isEmpty) return null;
    final current = _selectedExistingPlaylistId;
    if (current != null && playlists.any((p) => p.id == current)) {
      return current;
    }
    return playlists.first.id;
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<YoutubePlaylistInfo> _load() async {
    final info = await YoutubePlaylistService.fetchById(widget.playlistId);
    if (!mounted) return info;
    setState(() {
      _info = info;
      // Seed every track as "pending" so the list paints immediately.
      _trackStatus
        ..clear()
        ..addEntries(
          info.tracks.map((t) => MapEntry(t.id, _TrackStatus.pending)),
        );
    });
    return info;
  }

  // ---------------------------------------------------------------------------
  // Download orchestration
  // ---------------------------------------------------------------------------

  /// Sequentially downloads every track in [_info]. Sequential because:
  ///   * `DownloadService` resolves the on-disk path via stdout from
  ///     yt-dlp's `--print after_move:filepath`, but the legacy
  ///     mtime-based fallback can't disambiguate two writes that race
  ///     into the same directory;
  ///   * we want the UI to show one active track at a time anyway.
  ///
  /// Per-track failures are caught, logged, and surfaced as a "Failed"
  /// badge — the loop ALWAYS continues so a single bad video (private,
  /// region-locked, removed) doesn't strand the rest of the playlist.
  Future<void> _downloadAll() async {
    final info = _info;
    if (info == null || info.tracks.isEmpty || _downloading) return;

    final lib = context.read<LibraryService>();
    final messenger = ScaffoldMessenger.of(context);
    final root = await PlamusPaths.musicLibraryDirectory();

    // Resolve the destination picker selection into a concrete target
    // playlist id. All three destinations share the same per-track
    // download loop below; the only differences are whether
    // `plamusPlaylistId` is non-null (drives the
    // [LibraryService.addTrackToPlaylist] call per track) and whether
    // each track's library row is hidden from the main library view
    // (`saveToLibrary`).
    int? plamusPlaylistId;
    bool saveToLibrary;
    switch (_destination) {
      case _Destination.newPlaylist:
        // If the title is empty, fall back to a generic name with the
        // YouTube id so we still have something unique-ish.
        final playlistName = info.title.trim().isEmpty
            ? 'YouTube playlist ${info.id}'
            : info.title.trim();
        try {
          plamusPlaylistId = await lib.createPlaylist(playlistName);
        } catch (e) {
          // Non-fatal: keep going. Tracks will still land in the library.
          messenger.showSnackBar(
            SnackBar(content: Text('Could not create playlist: $e')),
          );
        }
        // A freshly-created playlist is the user's primary container
        // for this batch, so the tracks should live ONLY there. They
        // remain reachable from the playlist screen itself; the main
        // library view stays uncluttered.
        saveToLibrary = false;
      case _Destination.existingPlaylist:
        // Use the same derivation that drove the dropdown UI so the
        // target matches what the user saw. The derivation falls back
        // to the first playlist when the raw pick is stale or never
        // set, which matches the dropdown's auto-populated value.
        // `null` only when the user has zero playlists — in that case
        // fall through to library-only mode with an explanation.
        final effective = _effectiveExistingId(lib.playlists);
        if (effective != null) {
          plamusPlaylistId = effective;
          // The user explicitly picked an existing playlist as the
          // destination. Per the spec, the tracks should land ONLY in
          // that playlist and not also be appended to the general
          // library. `inLibrary: false` flips the library-list flag on
          // each new row so the track is reachable strictly from the
          // chosen playlist.
          saveToLibrary = false;
        } else {
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                'You have no playlists to add to — tracks will go '
                'to the library instead.',
              ),
            ),
          );
          saveToLibrary = true;
        }
      case _Destination.library:
        // `plamusPlaylistId` stays null: tracks are only registered in
        // the library and never linked to any playlist.
        saveToLibrary = true;
    }

    if (!mounted) return;
    setState(() {
      _downloading = true;
      _cancelled = false;
      _completed = 0;
      _failed = 0;
      _currentFraction = 0;
    });

    for (var i = 0; i < info.tracks.length; i++) {
      if (_cancelled || !mounted) break;

      // Wrap the entire iteration body so NOTHING — not even a stray
      // setState during a rebuild race — can break the loop. This is
      // critical for big playlists where a transient error on one
      // track must not strand the remaining 99% of the queue.
      try {
        final track = info.tracks[i];

        if (mounted) {
          setState(() {
            _currentFraction = 0;
            _trackStatus[track.id] = _TrackStatus.downloading;
          });
        }

        try {
          final result = await TrackDownloadHelper.download(
            url: track.url,
            libraryDirectory: root,
            onProgress: (fraction, _) {
              if (!mounted) return;
              setState(() => _currentFraction = fraction);
            },
          );

          // Register in the library and link into the corresponding
          // Plamus playlist (when we have a destination playlist).
          // `inLibrary` follows the destination semantics derived
          // above: only the explicit "Add to library" destination
          // surfaces tracks in the main library list.
          final trackId = await lib.registerTrackFile(
            result.filePath,
            // Prefer server-provided metadata; fall back to the
            // playlist's own title/channel since they tend to be
            // cleaner than yt-dlp-derived filenames.
            title:
                result.title?.isNotEmpty == true ? result.title : track.title,
            artist: result.artist?.isNotEmpty == true
                ? result.artist
                : track.channel,
            sourceUrl: track.url,
            artworkPath: result.artworkPath,
            inLibrary: saveToLibrary,
          );
          if (plamusPlaylistId != null) {
            await lib.addTrackToPlaylist(plamusPlaylistId, trackId);
          }

          if (!mounted) break;
          setState(() {
            _trackStatus[track.id] = _TrackStatus.done;
            _completed++;
          });
        } catch (e, st) {
          // Real-world playlists routinely contain age-restricted /
          // region-locked / removed videos. Each failure must be
          // contained so the loop continues with the next URL.
          debugPrint('Playlist download failed for ${track.url}: $e\n$st');
          if (!mounted) break;
          setState(() {
            _trackStatus[track.id] = _TrackStatus.failed;
            _failed++;
          });
        }
      } catch (e, st) {
        // Last-resort guard for anything that escaped the inner try
        // (setState exceptions during a rebuild race, framework
        // asserts, …). Log it and keep iterating — the user will see
        // failed badges and the summary at the end.
        debugPrint('Playlist iteration crashed: $e\n$st');
        if (!mounted) break;
      }
    }

    if (!mounted) return;
    try {
      await lib.refreshAll();
    } catch (_) {
      // Library refresh failure is non-fatal; the playlist screen
      // still renders the per-track badges and the summary below.
    }
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _currentFraction = 0;
    });

    final summary = _cancelled
        ? 'Stopped after $_completed tracks ($_failed failed).'
        : '$_completed tracks downloaded'
            '${_failed > 0 ? ', $_failed failed' : ''}.';
    messenger.showSnackBar(SnackBar(content: Text(summary)));
  }

  void _cancel() {
    if (!_downloading) return;
    setState(() => _cancelled = true);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          _info?.title.isNotEmpty == true ? _info!.title : widget.initialTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      // Persistent bottom player. The screen is always pushed as a
      // route (covering the shell), so we render the player UI here so
      // playback controls never disappear during the preview /
      // download phase.
      bottomNavigationBar: const GlassPlayerBar(),
      body: FutureBuilder<YoutubePlaylistInfo>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              _info == null) {
            return _buildLoadingHeader(theme);
          }
          if (snapshot.hasError && _info == null) {
            return _buildErrorState(theme, snapshot.error);
          }

          // Use the cached value preferentially so per-track state updates
          // during the download don't fight with the future's snapshot.
          final info = _info ?? snapshot.data!;
          return _buildLoaded(theme, info);
        },
      ),
    );
  }

  Widget _buildLoadingHeader(ThemeData theme) {
    return Column(
      children: [
        _Header(
          title: widget.initialTitle,
          channel: widget.initialChannel,
          thumbnail: widget.initialThumbnail,
          trackCount: widget.initialTrackCount,
          totalDurationSeconds: 0,
        ),
        const Expanded(
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
    );
  }

  Widget _buildErrorState(ThemeData theme, Object? error) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.error,
              size: 36,
            ),
            const SizedBox(height: 12),
            Text(
              'Could not load playlist',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              error?.toString() ?? '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
              onPressed: () => setState(() => _future = _load()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoaded(ThemeData theme, YoutubePlaylistInfo info) {
    // Displayed in the "Create new playlist" option subtitle so the user
    // can see exactly what the playlist will be called before tapping
    // "Download all". Mirrors the fallback used inside [_downloadAll].
    final newPlaylistName = info.title.trim().isEmpty
        ? 'YouTube playlist ${info.id}'
        : info.title.trim();

    // Watch the library so the "Add to existing playlist" dropdown stays
    // in sync if a playlist is created or deleted from elsewhere (e.g.
    // the sidebar) while this preview is open. `context.watch` triggers
    // a rebuild on every [LibraryService] notification, which is fine:
    // all local state (_completed, _failed, _trackStatus) is preserved
    // across rebuilds.
    final playlists = context.watch<LibraryService>().playlists;

    // Pure derivation of which existing-playlist id to show. Handles two
    // cases without mutating any state (would be unsafe in `build`):
    //   * user hasn't picked anything yet → fall back to `playlists.first`
    //   * user's pick was deleted elsewhere → fall back to `playlists.first`
    // The user's explicit pick is preserved via `_selectedExistingPlaylistId`
    // and will win on the next rebuild as long as it still exists.
    final effectiveExistingId = _effectiveExistingId(playlists);

    return Column(
      children: [
        _Header(
          title: info.title,
          channel: info.channel,
          thumbnail: info.thumbnail.isNotEmpty
              ? info.thumbnail
              : widget.initialThumbnail,
          trackCount:
              info.trackCount > 0 ? info.trackCount : info.tracks.length,
          totalDurationSeconds: info.totalDurationSeconds,
        ),
        _ActionBar(
          downloading: _downloading,
          completed: _completed,
          total: info.tracks.length,
          failed: _failed,
          currentFraction: _currentFraction,
          onDownload: info.tracks.isEmpty ? null : _downloadAll,
          onCancel: _cancel,
          destination: _destination,
          newPlaylistName: newPlaylistName,
          playlists: playlists,
          // Pass the *derived* id so the dropdown always has a valid
          // value — avoids Flutter asserting that DropdownButton.value
          // is one of its items when the user hasn't picked manually.
          selectedExistingPlaylistId: effectiveExistingId,
          onDestinationChanged: (d) => setState(() => _destination = d),
          onSelectedExistingPlaylistChanged: (id) =>
              setState(() => _selectedExistingPlaylistId = id),
        ),
        const Divider(height: 1),
        Expanded(
          child: info.tracks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'This playlist has no tracks.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: info.tracks.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final t = info.tracks[i];
                    final status = _trackStatus[t.id] ?? _TrackStatus.pending;
                    return _TrackRow(
                      index: i + 1,
                      track: t,
                      status: status,
                      progress: status == _TrackStatus.downloading
                          ? _currentFraction
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header — thumbnail + title + summary
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.channel,
    required this.thumbnail,
    required this.trackCount,
    required this.totalDurationSeconds,
  });

  final String title;
  final String channel;
  final String thumbnail;
  final int trackCount;
  final int totalDurationSeconds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 120,
              height: 68, // 16:9
              child: thumbnail.isEmpty
                  ? ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.queue_music),
                    )
                  : Image.network(
                      thumbnail,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.queue_music),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isEmpty ? 'Untitled playlist' : title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (channel.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    channel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.textTheme.bodySmall?.color
                          ?.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  _summary(),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _summary() {
    final parts = <String>[];
    if (trackCount > 0) {
      parts.add('$trackCount ${trackCount == 1 ? 'track' : 'tracks'}');
    }
    if (totalDurationSeconds > 0) {
      parts.add(formatLongDuration(totalDurationSeconds));
    }
    return parts.isEmpty ? '' : parts.join(' \u00b7 ');
  }
}

// ---------------------------------------------------------------------------
// Action bar — Download all / Cancel + progress text
// ---------------------------------------------------------------------------

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.downloading,
    required this.completed,
    required this.total,
    required this.failed,
    required this.currentFraction,
    required this.onDownload,
    required this.onCancel,
    required this.destination,
    required this.newPlaylistName,
    required this.playlists,
    required this.selectedExistingPlaylistId,
    required this.onDestinationChanged,
    required this.onSelectedExistingPlaylistChanged,
  });

  final bool downloading;
  final int completed;
  final int total;
  final int failed;
  final double currentFraction;
  final VoidCallback? onDownload;
  final VoidCallback onCancel;

  /// Currently-selected download destination (radio group value).
  final _Destination destination;

  /// Name the NEW playlist would be created with. Shown under the
  /// "Create new playlist" option so the user can confirm the target
  /// name before tapping Download.
  final String newPlaylistName;

  /// User's existing playlists. Drives the dropdown shown when
  /// [destination] is [_Destination.existingPlaylist]. When empty, the
  /// "Add to existing playlist" option is disabled.
  final List<PlaylistModel> playlists;

  /// Currently-selected existing playlist id (when [destination] is
  /// [_Destination.existingPlaylist]).
  final int? selectedExistingPlaylistId;

  /// Called when the user picks a different destination option.
  final ValueChanged<_Destination> onDestinationChanged;

  /// Called when the user picks a different existing playlist from the
  /// dropdown.
  final ValueChanged<int?> onSelectedExistingPlaylistChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // BUG FIX (off-by-one): the previous implementation used
    // `currentIndex + 1`, which counted the *in-flight* track as if it
    // had already finished — so the label read "Downloaded 5 of 10"
    // while only 4 tracks had actually completed. The summary now shows
    // `_completed`, which is only post-incremented inside `_downloadAll`
    // AFTER the track is fully processed (success: registered into the
    // library, failure: caught by the outer try / catch and counted in
    // `_failed`). This keeps the display accurate at every moment.
    final summary = downloading
        ? 'Downloaded $completed of $total'
            '${failed > 0 ? ' \u00b7 $failed failed' : ''}'
        : (total == 0
            ? 'Nothing to download'
            : '$total tracks ready to download');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DestinationPicker(
            destination: destination,
            newPlaylistName: newPlaylistName,
            playlists: playlists,
            selectedExistingPlaylistId: selectedExistingPlaylistId,
            enabled: !downloading && total > 0,
            onDestinationChanged: onDestinationChanged,
            onSelectedExistingPlaylistChanged:
                onSelectedExistingPlaylistChanged,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  summary,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 12),
              if (downloading)
                OutlinedButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                )
              else
                FilledButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download),
                  label: const Text('Download all'),
                ),
            ],
          ),
          if (downloading) ...[
            const SizedBox(height: 8),
            // Aggregate progress: completed-track ratio plus the in-flight
            // track's own fraction. Clamp to [0, 1] so a partial fraction
            // at the end of the loop doesn't overshoot.
            LinearProgressIndicator(
              value: total == 0
                  ? null
                  : ((completed + currentFraction) / total).clamp(0.0, 1.0),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Destination picker — "New playlist" / "Existing playlist" / "Library"
// ---------------------------------------------------------------------------

/// Three-way radio picker controlling where the tracks from this YouTube
/// playlist land:
///
///   1. **Create new playlist** — mirror the YouTube title into a brand
///      new Plamus playlist.
///   2. **Add to existing playlist** — append to one of the user's
///      pre-existing playlists, chosen via an inline dropdown that only
///      shows when this option is selected.
///   3. **Just add to library** — no playlist, tracks go to the main
///      library.
///
/// Lives directly above the "Download all" button. Visually it's a
/// single rounded card with three stacked rows — the accent-tinted
/// surface echoes the existing playlist cards (see
/// `HomeLibraryScreen`'s playlist tiles) so the control feels native to
/// the Plamus UI.
///
/// Disabled (dimmed, radios inert) while a download is running — the
/// decision is baked in the moment the user taps "Download all", so
/// flipping it mid-run would have no effect.
class _DestinationPicker extends StatelessWidget {
  const _DestinationPicker({
    required this.destination,
    required this.newPlaylistName,
    required this.playlists,
    required this.selectedExistingPlaylistId,
    required this.enabled,
    required this.onDestinationChanged,
    required this.onSelectedExistingPlaylistChanged,
  });

  final _Destination destination;
  final String newPlaylistName;
  final List<PlaylistModel> playlists;
  final int? selectedExistingPlaylistId;
  final bool enabled;
  final ValueChanged<_Destination> onDestinationChanged;
  final ValueChanged<int?> onSelectedExistingPlaylistChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final hasExistingPlaylists = playlists.isNotEmpty;

    // Subtitle for the "Add to existing" option depends on the live
    // state: no-playlists-at-all, one picked, or prompt-to-pick.
    final String existingSubtitle;
    if (!hasExistingPlaylists) {
      existingSubtitle =
          'You have no playlists yet — create one from the sidebar';
    } else if (destination == _Destination.existingPlaylist &&
        selectedExistingPlaylistId != null) {
      final selected = playlists.firstWhere(
        (p) => p.id == selectedExistingPlaylistId,
        orElse: () => playlists.first,
      );
      existingSubtitle = 'Appending to "${selected.name}"';
    } else {
      existingSubtitle = 'Pick one of your existing playlists';
    }

    final showDropdown =
        destination == _Destination.existingPlaylist && hasExistingPlaylists;

    return Material(
      color: primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            _DestinationOption(
              selected: destination == _Destination.newPlaylist,
              enabled: enabled,
              icon: Icons.playlist_add,
              title: 'Create new playlist',
              subtitle: 'Named "$newPlaylistName"',
              onTap: () => onDestinationChanged(_Destination.newPlaylist),
            ),
            _DestinationOption(
              selected: destination == _Destination.existingPlaylist,
              enabled: enabled && hasExistingPlaylists,
              icon: Icons.playlist_play,
              title: 'Add to existing playlist',
              subtitle: existingSubtitle,
              onTap: () => onDestinationChanged(_Destination.existingPlaylist),
            ),
            // Dropdown lives BELOW the option row, not as a trailing slot.
            // Avoids horizontal space fights on narrow screens (Android
            // ~360dp) with long playlist names. The left padding lines
            // up with the title/subtitle column above (dot + icon + gaps).
            if (showDropdown)
              Padding(
                padding: const EdgeInsets.fromLTRB(68, 0, 12, 8),
                child: _ExistingPlaylistDropdown(
                  playlists: playlists,
                  selectedId: selectedExistingPlaylistId,
                  enabled: enabled,
                  onChanged: onSelectedExistingPlaylistChanged,
                ),
              ),
            _DestinationOption(
              selected: destination == _Destination.library,
              enabled: enabled,
              icon: Icons.library_music,
              title: 'Just add to library',
              subtitle: 'No playlist — tracks go straight to the library',
              onTap: () => onDestinationChanged(_Destination.library),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single row inside [_DestinationPicker]: a radio dot, a themed icon,
/// and a two-line label. The "Add to existing playlist" option's
/// dropdown is rendered by [_DestinationPicker] directly below this
/// row, not inside it — that avoids horizontal space fights on narrow
/// screens (Android phones at ~360dp).
class _DestinationOption extends StatelessWidget {
  const _DestinationOption({
    required this.selected,
    required this.enabled,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final bool enabled;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final effectiveOpacity = enabled ? 1.0 : 0.5;

    return InkWell(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: effectiveOpacity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _RadioDot(selected: selected, color: primary),
              const SizedBox(width: 12),
              Icon(
                icon,
                size: 20,
                color: selected ? primary : theme.iconTheme.color,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.textTheme.bodySmall?.color
                            ?.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Filled circle radio indicator styled in the accent color. Hand-rolled
/// instead of using Material's [Radio] so we have full control over
/// sizing, padding, and disabled-state opacity within the picker row.
class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected, required this.color});

  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? color : color.withValues(alpha: 0.4),
          width: 2,
        ),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
            )
          : null,
    );
  }
}

/// Full-width dropdown rendered below the "Add to existing playlist"
/// option row.
///
/// [isExpanded: true] lets the button fill its parent's width so long
/// playlist names wrap gracefully to ellipsis instead of overflowing.
/// The underline is suppressed — the picker already sits on an
/// accent-tinted surface, so a heavy Material underline would read as
/// visual noise. The body is wrapped in a subtle outlined container so
/// the dropdown reads as a distinct affordance (not just another row of
/// text) against the destination picker's background.
class _ExistingPlaylistDropdown extends StatelessWidget {
  const _ExistingPlaylistDropdown({
    required this.playlists,
    required this.selectedId,
    required this.enabled,
    required this.onChanged,
  });

  final List<PlaylistModel> playlists;
  final int? selectedId;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.4),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: selectedId,
          isDense: true,
          isExpanded: true,
          icon: const Icon(Icons.arrow_drop_down),
          borderRadius: BorderRadius.circular(8),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
          items: playlists
              .where((p) => p.id != null)
              .map(
                (p) => DropdownMenuItem<int>(
                  value: p.id,
                  child: Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Individual track row
// ---------------------------------------------------------------------------

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.index,
    required this.track,
    required this.status,
    required this.progress,
  });

  final int index;
  final YoutubePlaylistTrack track;
  final _TrackStatus status;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: SizedBox(
        width: 32,
        child: Center(
          child: Text(
            '$index',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
      title: Text(
        track.title.isEmpty ? 'Unknown track' : track.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Row(
        children: [
          if (track.channel.isNotEmpty)
            Flexible(
              child: Text(
                track.channel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                ),
              ),
            ),
          if (track.channel.isNotEmpty && track.durationSeconds > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '\u00b7',
                style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      theme.textTheme.bodySmall?.color?.withValues(alpha: 0.5),
                ),
              ),
            ),
          if (track.durationSeconds > 0)
            Text(
              formatShortDuration(track.durationSeconds),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
              ),
            ),
        ],
      ),
      trailing: _statusIcon(theme),
    );
  }

  Widget _statusIcon(ThemeData theme) {
    switch (status) {
      case _TrackStatus.pending:
        return const SizedBox(width: 24, height: 24);
      case _TrackStatus.downloading:
        return SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            value: (progress != null && progress! > 0) ? progress : null,
          ),
        );
      case _TrackStatus.done:
        return Icon(
          Icons.check_circle,
          color: theme.colorScheme.primary,
        );
      case _TrackStatus.failed:
        return Icon(
          Icons.error_outline,
          color: theme.colorScheme.error,
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Duration formatting helpers (also used by the search tile)
// ---------------------------------------------------------------------------

/// Formats [seconds] as `m:ss` (under one hour) or `h:mm:ss`, suitable
/// for compact per-track labels. Returns an empty string for non-positive
/// values so the caller can hide the label entirely.
String formatShortDuration(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) {
    final mm = m.toString().padLeft(2, '0');
    return '$h:$mm:$ss';
  }
  return '$m:$ss';
}

/// Formats [seconds] as `Xh Ym` for the playlist header — that scale
/// usually adds up to multiple hours, so a verbose format reads better
/// than `h:mm:ss`.
String formatLongDuration(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0 && m > 0) return '${h}h ${m}m';
  if (h > 0) return '${h}h';
  if (m > 0) return '${m}m';
  return '${seconds}s';
}
