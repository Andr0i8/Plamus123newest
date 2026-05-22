import 'binary_service.dart';
import 'download_service.dart';

/// Outcome of a single per-track download.
///
/// [filePath] is the absolute path to the saved audio file in the
/// library directory. [artworkPath] points at a sibling JPG with the
/// YouTube thumbnail when the download backend was able to fetch one.
/// `null` for non-YouTube downloads, network failures, or when the user
/// disabled artwork later — the UI handles the placeholder fallback.
class SingleTrackDownloadResult {
  /// Creates a result.
  const SingleTrackDownloadResult({
    required this.filePath,
    this.title,
    this.artist,
    this.artworkPath,
  });

  final String filePath;
  final String? title;
  final String? artist;
  final String? artworkPath;
}

/// Centralized per-track download entry point.
///
/// Shared between the single-tap import flow in
/// [`ImportPanel`](../ui/widgets/import_panel.dart) and the
/// "Download all" action in
/// [`PlaylistPreviewScreen`](../ui/screens/playlist_preview_screen.dart).
/// Centralizing the launch in one place ensures every code path
/// downloads identically — there's no chance of the playlist downloader
/// drifting away from the single-track downloader.
///
/// Plamus is desktop-only; this routes through [DownloadService] which
/// runs the bundled / first-run-downloaded `yt-dlp` binary directly.
/// `--no-playlist` prevents accidental playlist expansion when a watch
/// URL happens to have a `list=` parameter.
///
/// The [onProgress] callback is invoked with a `[0.0, 1.0]` fraction
/// and a short status message, matching the shape the rest of the
/// import UI already consumes.
class TrackDownloadHelper {
  TrackDownloadHelper._();

  /// Downloads [url] into [libraryDirectory] and returns the saved path
  /// plus any metadata the download provided.
  ///
  /// Throws on platform-specific errors:
  ///   * yt-dlp missing
  ///   * any IO / network failure mid-stream
  ///
  /// Callers are responsible for catching these exceptions and
  /// surfacing a friendly message; the playlist preview screen, for
  /// example, marks the failing row as "Failed" but keeps downloading
  /// the rest.
  static Future<SingleTrackDownloadResult> download({
    required String url,
    required String libraryDirectory,
    void Function(double fraction, String message)? onProgress,
  }) async {
    final bin = BinaryService.instance.lastResolution;
    if (bin == null || !bin.ytDlpAvailable) {
      final detail =
          bin != null ? bin.errors.join(' ') : 'Binary resolution did not run.';
      throw StateError('yt-dlp is not available. $detail');
    }

    final result = await DownloadService.downloadUrlToMp3WithArtwork(
      url: url,
      outputDirectory: libraryDirectory,
      ytDlpExecutablePath: bin.ytDlpPath,
      onProgress: (p) => onProgress?.call(p.fraction, p.message),
    );

    return SingleTrackDownloadResult(
      filePath: result.filePath,
      artworkPath: result.artworkPath,
    );
  }
}
