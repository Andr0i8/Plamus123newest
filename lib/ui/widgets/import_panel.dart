import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/audio_download_service.dart';
import '../../services/binary_service.dart';
import '../../services/download_service.dart';
import '../../services/library_service.dart';
import '../../services/media_ingest_service.dart';
import '../../services/plamus_paths.dart';
import '../../services/youtube_search_service.dart';

/// Internal mode for the panel: paste a link vs. live YouTube search.
enum _ImportMode { link, search }

/// Shared import UI: URL field, pick files, drag-and-drop (desktop), and
/// a YouTube search tab backed by the Plamus Railway extraction server.
///
/// The search tab is available on every platform (Windows, Linux, macOS,
/// Android, iOS). The download path still differs per-platform:
/// desktop uses the bundled `yt-dlp` binary; mobile routes via the Railway
/// `/download` endpoint (see `YoutubeDownloadService`).
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

  _ImportMode _mode = _ImportMode.link;

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

  /// Validates [url] for the active platform and returns an inline error
  /// message, or `null` when the URL passes all checks.
  String? _validateUrlForCurrentPlatform(String url) {
    if (url.isEmpty) {
      return 'Please paste a link first.';
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return 'Please add https:// at the start of the URL';
    }
    final isMobile = Platform.isAndroid || Platform.isIOS;
    if (isMobile && !AudioDownloadService.isYouTubeUrl(url)) {
      // The mobile extractor server only handles YouTube; anything else
      // either gets a broken HTML body back (VK, SoundCloud pages) or is
      // outside the scope of what we ship today. Fail fast (BUG 5).
      return 'Only YouTube links are supported';
    }
    return null;
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
  /// When [overrideUrl] is null the URL is read from [_urlCtrl] (link tab);
  /// search-result taps pass the result URL directly so they can reuse this
  /// pipeline without round-tripping through the text field.
  ///
  /// Mobile (Android/iOS): unified [AudioDownloadService]. YouTube URLs are
  /// forwarded to a remote extraction server (see `YoutubeDownloadService`);
  /// the server may include `X-Track-Title` / `X-Track-Artist` headers
  /// which we propagate to [LibraryService.registerTrackFile] so the row
  /// is created with the real channel name (BUG 2).
  ///
  /// Desktop (Windows/Linux/macOS): yt-dlp binary via [DownloadService] for
  /// broad site support and proper MP3 transcoding.
  Future<void> _downloadUrl({String? overrideUrl}) async {
    final url = (overrideUrl ?? _urlCtrl.text).trim();

    final validationError = _validateUrlForCurrentPlatform(url);
    if (validationError != null) {
      await _setBusy(false, error: validationError);
      return;
    }

    final lib = context.read<LibraryService>();
    await _setBusy(true, p: 0, msg: 'Starting download\u2026', error: null);

    try {
      final root = await PlamusPaths.musicLibraryDirectory();
      String outputPath;
      String? remoteTitle;
      String? remoteArtist;

      if (Platform.isAndroid || Platform.isIOS) {
        // Mobile: pure-Dart audio download (YouTube) with metadata.
        final result =
            await AudioDownloadService.instance.downloadAudioWithMetadata(
          url: url,
          outputDirectory: root,
          onProgress: (p) {
            if (!mounted) return;
            setState(() {
              _progress = p;
              _status = 'Downloading\u2026 ${(p * 100).toStringAsFixed(0)}%';
              _errorMessage = null;
            });
          },
          onLog: (msg) {
            if (!mounted) return;
            setState(() => _status = msg);
          },
        );
        outputPath = result.filePath;
        remoteTitle = result.title;
        remoteArtist = result.artist;
      } else {
        // Desktop: yt-dlp binary supports many sites natively, so we don't
        // restrict to YouTube here. Title / artist tagging from yt-dlp is
        // out of scope for this fix — the row falls back to filename /
        // "Unknown" exactly like before.
        final bin = BinaryService.instance.lastResolution;
        if (bin == null || !bin.ytDlpAvailable) {
          final detail = bin != null
              ? bin.errors.join(' ')
              : 'Binary resolution did not run.';
          await _setBusy(false, error: 'yt-dlp is not available. $detail');
          return;
        }

        outputPath = await DownloadService.downloadUrlToMp3(
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
      }

      final id = await lib.registerTrackFile(
        outputPath,
        artist: remoteArtist,
        title: remoteTitle,
        inLibrary: widget.addToLibrary,
      );
      await lib.refreshAll();
      widget.onTrackImported?.call(id);
      // Only clear the URL field if it was actually used to drive the
      // download; tapping a search result must not blow away anything the
      // user typed in the link tab.
      if (overrideUrl == null) {
        _urlCtrl.clear();
      }
      widget.onDone?.call();
      await _setBusy(false, p: 1, msg: 'Download complete.', error: null);
    } catch (_) {
      // Map opaque server / network errors to a single friendly inline
      // message — the previous version surfaced raw exception text in a
      // pink snackbar (BUG 4).
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
  // Search tab (Linux desktop only)
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
  /// Reuses [_downloadUrl] so progress, error handling, and library
  /// registration are identical to the link-paste flow.
  Future<void> _onSearchResultTap(YoutubeSearchResult result) async {
    if (_busy) return;
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
    final isMobile = Platform.isAndroid || Platform.isIOS;

    // Only show binary errors on desktop where they matter.
    final bin = isMobile ? null : BinaryService.instance.lastResolution;

    // Pick the section for the current tab. Wrapped in [Expanded] when
    // [widget.fillHeight] is true so the panel fills the parent instead of
    // forcing an outer scroll view (BUG 4).
    final Widget tabSection =
        (_mode == _ImportMode.link || !_supportsSearch)
            ? _buildLinkSection(theme, isMobile: isMobile)
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
  // Mode toggle (Link / Search)
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
        segments: const [
          ButtonSegment(
            value: _ImportMode.link,
            label: Text('Link'),
            icon: Icon(Icons.link),
          ),
          ButtonSegment(
            value: _ImportMode.search,
            label: Text('Search'),
            icon: Icon(Icons.search),
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
  // Link section (existing UX)
  // ---------------------------------------------------------------------------

  Widget _buildLinkSection(ThemeData theme, {required bool isMobile}) {
    // The drop zone expands to fill remaining vertical space when
    // [widget.fillHeight] is true (BUG 4: no outer scroll needed). When
    // the parent gives us unbounded height (e.g. a bottom-sheet scroll
    // view) we fall back to a fixed 220px so `Expanded` doesn't blow up.
    final Widget? dropZone = isMobile
        ? null
        : DropTarget(
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
            hintText: isMobile
                ? 'Paste YouTube link'
                : 'Paste YouTube, web audio, or video URL',
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
        if (dropZone != null) ...[
          const SizedBox(height: 16),
          if (widget.fillHeight)
            Expanded(child: dropZone)
          else
            SizedBox(height: 220, child: dropZone),
        ],
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
                child: Image.network(
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
                    child: const Icon(Icons.broken_image, size: 18),
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
                    result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    result.channel,
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
            const SizedBox(width: 8),
            const Icon(Icons.download, size: 18),
          ],
        ),
      ),
    );
  }
}
