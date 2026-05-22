import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/binary_service.dart';
import '../../services/download_service.dart';
import '../../services/library_service.dart';
import '../../services/media_ingest_service.dart';
import '../../services/plamus_paths.dart';
import '../../services/youtube_search_service.dart';
import '../screens/playlist_preview_screen.dart';

/// Internal mode for the panel: live YouTube search vs. paste a link.
///
/// Order matters: `search` is declared first because it is the default
/// and leftmost tab in the UI (the primary way to add music). Paste-a-link
/// is available as a secondary tab for users who already have a URL.
enum _ImportMode { search, link }

/// Shared import UI with two tabs:
///
///   1. **Search** (default / primary) — live YouTube search backed by
///      the Plamus Railway extraction server. This is the recommended
///      way to add music and is shown first on every platform.
///   2. **Link** (secondary) — paste a URL + optional pick-files /
///      drag-and-drop (desktop) for users who already have a direct
///      link or a local audio file to ingest.
///
/// The search tab is available on every platform (Windows, Linux, macOS,
/// Android, iOS). The download path still differs per-platform:
/// desktop uses the bundled `yt-dlp` binary; mobile routes via the
/// self-hosted yt-dlp Flask server (see `YoutubeDownloadService`).
///
/// Validation behavior (BUG 4 / BUG 5):
///   * Empty / non-http(s) URLs are rejected inline with a red field error
///     instead of a snackbar.
///   * On Android / iOS, only YouTube links are accepted. Anything else
///     would be routed through our YouTube-only Railway extractor or the
///     plain-HTTP fallback that produces broken files for sites like VK,
///     so we tell the user up-front rather than letting the download
///     fail later.
///
/// Library / playlist mode (BUG 6):
///   * [addToLibrary] = `true` (default) → imported tracks appear in the
///     main library list. Used by the global Search / Import flow.
///   * [addToLibrary] = `false` → imported tracks are saved with
///     `inLibrary = 0` and are only reachable through whichever playlist
///     the caller subsequently links them to via [onTrackImported].
///
/// Layout:
///   * [fillHeight] = `true` → the panel expands to fill its parent's
///     vertical space. Drag-and-drop and search-results areas use
///     `Expanded` so no outer scroll is needed (BUG 4 fix for the full
///     Search / import page and the import modal).
///   * [fillHeight] = `false` (default) → the drag-drop area and search
///     results list use fixed heights, matching the historic behavior so
///     the panel can still embed inside a `SingleChildScrollView` (e.g.
///     playlist-detail's bottom sheet).
///
/// [onTrackImported] is invoked with the new track's id after every
/// successful import so callers can wire it into a playlist if needed.
class ImportPanel extends StatefulWidget {
  /// Creates the import panel.
  const ImportPanel({
    super.key,
    this.onDone,
    this.onTrackImported,
    this.addToLibrary = true,
    this.fillHeight = false,
  });

  /// Called once after every successful import (URL or file).
  final VoidCallback? onDone;

  /// Called with the new track's id after every successful import. Used
  /// by playlist-detail's "Import new track" flow to link the new row
  /// into the playlist via `addTrackToPlaylist`.
  final ValueChanged<int>? onTrackImported;

  /// Whether to surface imported tracks in the main library. See class
  /// docs.
  final bool addToLibrary;

  /// When `true`, the variable-height sections (drag-and-drop, search
  /// results) expand to fill the parent. See class docs.
  final bool fillHeight;

  @override
  State<ImportPanel> createState() => _ImportPanelState();
}

class _ImportPanelState extends State<ImportPanel> {
  final _urlCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  bool _busy = false;
  double _progress = 0;
  String _status = '';

  /// Inline error displayed via the URL field's `errorText` (red border +
  /// red helper line). Replaces the previous pink error snackbar.
  String? _errorMessage;

  // Default to the search tab: the primary, discovery-driven way to add
  // music. Users who already have a URL tap the secondary "Link" tab.
  _ImportMode _mode = _ImportMode.search;

  /// Latest debounced search query token. Used so that a slow in-flight
  /// request does not overwrite the results of a newer query.
  int _searchToken = 0;

  /// 500ms debounce timer guarding the live search request.
  Timer? _debounce;

  bool _searchLoading = false;
  String? _searchError;
  List<YoutubeSearchResult> _searchResults = const [];

  /// True when the platform should expose the live YouTube search tab.
  /// The Railway server handles every platform, so the search UX is
  /// available everywhere now (Linux / Windows / macOS / Android / iOS).
  bool get _supportsSearch => true;

  @override
  void dispose() {
    _debounce?.cancel();
    _urlCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _setBusy(
    bool v, {
    double p = 0,
    String msg = '',
    String? error,
  }) async {
    if (!mounted) return;
    setState(() {
      _busy = v;
      _progress = p;
      _status = msg;
      _errorMessage = error;
    });
  }

  /// Validates [url] and returns an inline error message, or `null`
  /// when the URL passes all checks. yt-dlp can pull audio from the
  /// vast majority of media hosts (YouTube, SoundCloud, Bandcamp, …)
  /// so we only enforce a basic shape check.
  String? _validateUrl(String url) {
    if (url.isEmpty) {
      return 'Please paste a link first.';
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return 'Please add https:// at the start of the URL';
    }
    return null;
  }

  /// Whether [url] looks like a YouTube video URL or bare 11-char id.
  /// Used purely to decide whether to persist the URL as the track's
  /// `sourceUrl` (only YouTube links are interesting to share).
  static bool _isYouTubeUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('youtube-nocookie.com') ||
        RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(url.trim());
  }

  /// Imports a local path (file picker or drop).
  Future<void> _ingestPath(String path) async {
    final lib = context.read<LibraryService>();
    await _setBusy(true, p: 0.05, msg: 'Importing\u2026', error: null);
    try {
      final root = await PlamusPaths.musicLibraryDirectory();
      final id = await MediaIngestService.ingestAndRegister(
        sourcePath: path,
        libraryDirectory: root,
        inLibrary: widget.addToLibrary,
        onLog: (m) {
          if (!mounted) return;
          setState(() => _status = m);
        },
      );
      await lib.refreshAll();
      widget.onTrackImported?.call(id);
      widget.onDone?.call();
      await _setBusy(false, msg: 'Done.');
    } catch (e) {
      await _setBusy(false, error: 'Import failed: $e');
    }
  }

  /// Downloads a remote URL.
  ///
  /// When [overrideUrl] is null the URL is read from [_urlCtrl] (link
  /// tab); search-result taps pass the result URL directly so they can
  /// reuse this pipeline without round-tripping through the text field.
  ///
  /// Plamus is desktop-only, so this always runs the bundled / first-run
  /// `yt-dlp` binary locally via [DownloadService]. Artwork is
  /// best-effort: only YouTube URLs surface a JPG; other hosts leave
  /// `artworkPath` null and the UI falls back to the placeholder.
  Future<void> _downloadUrl({String? overrideUrl}) async {
    final url = (overrideUrl ?? _urlCtrl.text).trim();

    final validationError = _validateUrl(url);
    if (validationError != null) {
      await _setBusy(false, error: validationError);
      return;
    }

    final lib = context.read<LibraryService>();
    await _setBusy(true, p: 0, msg: 'Starting download\u2026', error: null);

    try {
      final bin = BinaryService.instance.lastResolution;
      if (bin == null || !bin.ytDlpAvailable) {
        final detail = bin != null
            ? bin.errors.join(' ')
            : 'Binary resolution did not run.';
        await _setBusy(false, error: 'yt-dlp is not available. $detail');
        return;
      }

      final root = await PlamusPaths.musicLibraryDirectory();
      final result = await DownloadService.downloadUrlToMp3WithArtwork(
        url: url,
        outputDirectory: root,
        ytDlpExecutablePath: bin.ytDlpPath,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p.fraction;
            _status = p.message;
            _errorMessage = null;
          });
        },
      );

      final id = await lib.registerTrackFile(
        result.filePath,
        sourceUrl: _isYouTubeUrl(url) ? url : null,
        artworkPath: result.artworkPath,
        inLibrary: widget.addToLibrary,
      );
      await lib.refreshAll();
      widget.onTrackImported?.call(id);
      // Only clear the URL field if it was actually used to drive the
      // download; tapping a search result must not blow away anything
      // the user typed in the link tab.
      if (overrideUrl == null) {
        _urlCtrl.clear();
      }
      widget.onDone?.call();
      await _setBusy(false, p: 1, msg: 'Download complete.', error: null);
    } catch (_) {
      // Map opaque server / network errors to a single friendly inline
      // message — the previous version surfaced raw exception text in a
      // pink snackbar.
      await _setBusy(false, error: 'Invalid or unsupported URL');
    }
  }

  Future<void> _pickFiles() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null || res.files.isEmpty) return;
    for (final f in res.files) {
      final path = f.path ?? '';
      if (path.isEmpty) continue;
      await _ingestPath(path);
    }
  }

  // ---------------------------------------------------------------------------
  // Search tab (default / primary — available on every platform)
  // ---------------------------------------------------------------------------

  /// Called on every keystroke. Cancels any in-flight debounce, then waits
  /// 500ms before actually firing the search request so we don't hammer
  /// the server while the user types.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      // Empty box: drop any prior results immediately so the list does not
      // linger with stale data.
      setState(() {
        _searchResults = const [];
        _searchError = null;
        _searchLoading = false;
      });
      return;
    }
    setState(() => _searchLoading = true);
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _runSearch(query);
    });
  }

  /// Performs the actual search request. Uses [_searchToken] so a stale
  /// response from an older query can never overwrite the visible results
  /// of a newer one.
  Future<void> _runSearch(String query) async {
    final token = ++_searchToken;
    try {
      final results = await YoutubeSearchService.search(query);
      if (!mounted || token != _searchToken) return;
      setState(() {
        _searchResults = results;
        _searchError = null;
        _searchLoading = false;
      });
    } catch (_) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _searchResults = const [];
        _searchError = 'Search unavailable';
        _searchLoading = false;
      });
    }
  }

  /// Triggered when the user taps a result row.
  ///
  /// Behavior depends on the result kind:
  ///   * **Video** — reuses [_downloadUrl] so progress, error handling,
  ///     and library registration are identical to the link-paste flow.
  ///     [widget.onDone] fires after a successful download, matching the
  ///     pre-existing behavior (e.g. closing the host import modal).
  ///   * **Playlist** — pushes [PlaylistPreviewScreen], which fetches
  ///     the full track list from `/playlist` and offers a "Download
  ///     all" action that drives the same per-track pipeline (one URL
  ///     at a time) via [TrackDownloadHelper]. The panel stays idle
  ///     while the preview screen is on top, so the URL field /
  ///     drag-and-drop continue to work after the user pops back. We
  ///     deliberately do NOT call [widget.onDone] for playlist taps:
  ///     the user might want to keep searching, and the preview screen
  ///     itself surfaces a snackbar summarising the bulk download.
  Future<void> _onSearchResultTap(YoutubeSearchResult result) async {
    if (_busy) return;
    if (result.isPlaylist) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlaylistPreviewScreen(
            playlistId: result.id,
            playlistUrl: result.url,
            initialTitle: result.title,
            initialChannel: result.channel,
            initialThumbnail: result.thumbnail,
            initialTrackCount: result.trackCount,
          ),
        ),
      );
      // Refresh the library after we come back so any newly-downloaded
      // tracks show up immediately in the host (library list, etc.).
      // Guarded by `mounted` because the panel may have been disposed.
      if (!mounted) return;
      await context.read<LibraryService>().refreshAll();
      return;
    }
    await _setBusy(
      true,
      p: 0,
      msg: 'Starting download: ${result.title}',
      error: null,
    );
    await _downloadUrl(overrideUrl: result.url);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Surface binary-resolution errors inline so missing yt-dlp / ffmpeg
    // is obvious before the user tries to download.
    final bin = BinaryService.instance.lastResolution;

    // Pick the section for the current tab. Wrapped in [Expanded] when
    // [widget.fillHeight] is true so the panel fills the parent instead
    // of forcing an outer scroll view.
    final Widget tabSection = (_mode == _ImportMode.link || !_supportsSearch)
        ? _buildLinkSection(theme)
        : _buildSearchSection(theme);
    final wrappedTabSection =
        widget.fillHeight ? Expanded(child: tabSection) : tabSection;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (bin != null && bin.errors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Material(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  bin.errors.join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          ),
        if (_supportsSearch) _buildModeToggle(theme),
        wrappedTabSection,
        if (_busy || _status.isNotEmpty) ...[
          const SizedBox(height: 12),
          if (_busy)
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _status,
                style: theme.textTheme.bodySmall,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Mode toggle (Search / Link)
  // ---------------------------------------------------------------------------

  Widget _buildModeToggle(ThemeData theme) {
    // BUG 3: the default Material-3 SegmentedButton uses a teal-ish
    // `secondaryContainer` fill for the selected segment, which clashes
    // with Plamus' accent color. Style the selected state to use the
    // theme's `primary` (the user's accent color) so the toggle matches
    // every other filled control in the app.
    final primary = theme.colorScheme.primary;
    final onPrimary = theme.colorScheme.onPrimary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SegmentedButton<_ImportMode>(
        // Search first (primary) and Link second (secondary) so the
        // discovery-driven flow is the default on every platform.
        segments: const [
          ButtonSegment(
            value: _ImportMode.search,
            label: Text('Search'),
            icon: Icon(Icons.search),
          ),
          ButtonSegment(
            value: _ImportMode.link,
            label: Text('Link'),
            icon: Icon(Icons.link),
          ),
        ],
        selected: {_mode},
        onSelectionChanged: _busy
            ? null
            : (selection) {
                setState(() => _mode = selection.first);
              },
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return primary;
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return onPrimary;
            return theme.colorScheme.onSurface;
          }),
          iconColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return onPrimary;
            return theme.colorScheme.onSurface;
          }),
          side: WidgetStatePropertyAll(
            BorderSide(color: primary.withValues(alpha: 0.6)),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Link section (secondary — for users who already have a URL)
  // ---------------------------------------------------------------------------

  Widget _buildLinkSection(ThemeData theme) {
    // The drop zone expands to fill remaining vertical space when
    // [widget.fillHeight] is true (no outer scroll needed). When the
    // parent gives us unbounded height (e.g. a bottom-sheet scroll
    // view) we fall back to a fixed 220px so `Expanded` doesn't blow up.
    final Widget dropZone = DropTarget(
      onDragDone: (detail) async {
        if (_busy) return;
        for (final f in detail.files) {
          final path = f.path;
          if (path.isEmpty) continue;
          await _ingestPath(path);
        }
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.dividerColor.withValues(alpha: 0.4),
          ),
        ),
        child: Center(
          child: Text(
            'Drag and drop audio or video files here',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.textTheme.bodyLarge?.color
                  ?.withValues(alpha: 0.75),
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _urlCtrl,
          decoration: InputDecoration(
            labelText: 'Media link',
            hintText: 'Paste YouTube, web audio, or video URL',
            border: const OutlineInputBorder(),
            // The TextField's own errorText drives the red border + the
            // red helper line below the field, replacing the old snackbar.
            errorText: _errorMessage,
          ),
          onChanged: (_) {
            // Clear stale error as the user types so the red state doesn't
            // linger after they fix the URL.
            if (_errorMessage != null) {
              setState(() => _errorMessage = null);
            }
          },
          onSubmitted: (_) => _downloadUrl(),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _downloadUrl(),
              icon: const Icon(Icons.download),
              label: const Text('Download audio'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickFiles,
              icon: const Icon(Icons.folder_open),
              label: const Text('Browse files'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (widget.fillHeight)
          Expanded(child: dropZone)
        else
          SizedBox(height: 220, child: dropZone),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Search section
  // ---------------------------------------------------------------------------

  Widget _buildSearchSection(ThemeData theme) {
    final results = _SearchResultsList(
      loading: _searchLoading,
      error: _searchError,
      results: _searchResults,
      query: _searchCtrl.text,
      onTap: _busy ? null : _onSearchResultTap,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchCtrl,
          decoration: const InputDecoration(
            labelText: 'Search YouTube',
            hintText: 'Type a song or artist',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
          onChanged: _onSearchChanged,
        ),
        const SizedBox(height: 12),
        // Results list expands to fill when the parent gives us a bounded
        // height; otherwise fall back to a fixed 320 so the panel stays
        // embeddable inside scroll views.
        if (widget.fillHeight)
          Expanded(child: results)
        else
          SizedBox(height: 320, child: results),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Search results list
// ---------------------------------------------------------------------------

/// Scrollable list of [YoutubeSearchResult]s with the same loading / error
/// / empty states the design requires.
///
/// Pulled out as its own widget to keep [_ImportPanelState.build] readable
/// — the panel's body is already large enough.
class _SearchResultsList extends StatelessWidget {
  const _SearchResultsList({
    required this.loading,
    required this.error,
    required this.results,
    required this.query,
    required this.onTap,
  });

  final bool loading;
  final String? error;
  final List<YoutubeSearchResult> results;

  /// Current text in the search field. Used to differentiate "I haven't
  /// typed anything yet" from "I typed something and got 0 hits".
  final String query;

  /// Tap handler. `null` disables tap (e.g. while a download is running).
  final ValueChanged<YoutubeSearchResult>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget centered(Widget child) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        );

    if (loading) {
      return centered(
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      );
    }
    if (error != null) {
      return centered(
        Text(
          error!,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (query.trim().isEmpty) {
      return centered(
        Text(
          'Start typing to search YouTube.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
          ),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (results.isEmpty) {
      return centered(
        Text(
          'No results found',
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.4),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: results.length,
          separatorBuilder: (_, __) => Divider(
            height: 1,
            color: theme.dividerColor.withValues(alpha: 0.4),
          ),
          itemBuilder: (context, i) {
            final r = results[i];
            return _SearchResultTile(
              result: r,
              onTap: onTap == null ? null : () => onTap!(r),
            );
          },
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.result, required this.onTap});

  final YoutubeSearchResult result;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Subtitle: channel · (duration | "N tracks"). Channel and the
    // metadata field are joined only when both are present so we don't
    // render stray bullets.
    final metaLabel = result.isPlaylist
        ? (result.trackCount > 0
            ? '${result.trackCount} '
                '${result.trackCount == 1 ? 'track' : 'tracks'}'
            : '')
        : formatShortDuration(result.durationSeconds);
    final subtitleText = [
      if (result.channel.isNotEmpty) result.channel,
      if (metaLabel.isNotEmpty) metaLabel,
    ].join(' \u00b7 ');
    final trailingIcon = result.isPlaylist ? Icons.queue_music : Icons.download;
    // Tag rendered on top of the thumbnail so playlists are visually
    // distinct at a glance even before you read the subtitle.
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 96,
                height: 54, // 16:9 thumbnail
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      result.thumbnail,
                      fit: BoxFit.cover,
                      // Avoid layout jump while the image loads.
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      },
                      errorBuilder: (_, __, ___) => ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          result.isPlaylist
                              ? Icons.queue_music
                              : Icons.broken_image,
                          size: 18,
                        ),
                      ),
                    ),
                    if (result.isPlaylist)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.queue_music,
                                size: 10,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Playlist',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: Colors.white,
                                  fontSize: 10,
                                  height: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitleText.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitleText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.textTheme.bodySmall?.color
                            ?.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(trailingIcon, size: 18),
          ],
        ),
      ),
    );
  }
}
