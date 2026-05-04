import 'dart:io';

import 'audio_download_service.dart';
import 'binary_service.dart';
import 'download_service.dart';

/// Outcome of a single per-track download.
///
/// [filePath] is the absolute path to the saved audio file in the library
/// directory. [title] / [artist] are best-effort metadata returned by the
/// server-backed extractor on mobile; both are `null` on desktop because
/// yt-dlp runs locally and we let `LibraryService.registerTrackFile`
/// derive the title from the filename (matching pre-existing behavior).
class SingleTrackDownloadResult {
  /// Creates a result.
  const SingleTrackDownloadResult({
    required this.filePath,
    this.title,
    this.artist,
  });

  final String filePath;
  final String? title;
  final String? artist;
}

/// Picks the right per-track download backend for the running platform
/// and runs it to completion.
///
/// This is shared between the existing single-tap import flow in
/// [`ImportPanel`](../ui/widgets/import_panel.dart) and the new
/// "Download all" action in
/// [`PlaylistPreviewScreen`](../ui/screens/playlist_preview_screen.dart).
/// Centralizing the platform fork in one place ensures every code path
/// downloads identically — there's no chance of the playlist downloader
/// drifting away from the single-track downloader.
///
/// Behavior per platform:
///
///   * **Android / iOS** — delegates to the server-backed
///     [AudioDownloadService] (which talks to `/download` on Railway).
///     YouTube URLs surface the optional `X-Track-Title` /
///     `X-Track-Artist` headers as [SingleTrackDownloadResult.title] /
///     [SingleTrackDownloadResult.artist].
///
///   * **Linux / Windows / macOS** — runs the bundled `yt-dlp` binary
///     via [DownloadService] (no server roundtrip for the actual audio).
///     yt-dlp's `--no-playlist` flag prevents accidental playlist
///     expansion when a watch URL happens to have a `list=` parameter.
///
/// The [onProgress] callback is invoked with a `[0.0, 1.0]` fraction and
/// a short status message, matching the shape the rest of the import UI
/// already consumes.
class TrackDownloadHelper {
  TrackDownloadHelper._();

  /// Downloads [url] into [libraryDirectory] and returns the saved path
  /// plus any metadata the server provided.
  ///
  /// Throws on platform-specific errors:
  ///   * yt-dlp missing (desktop)
  ///   * extractor server unreachable (mobile)
  ///   * any IO / network failure mid-stream
  ///
  /// Callers are responsible for catching these exceptions and surfacing
  /// a friendly message; the playlist preview screen, for example, marks
  /// the failing row as "Failed" but keeps downloading the rest.
  static Future<SingleTrackDownloadResult> download({
    required String url,
    required String libraryDirectory,
    void Function(double fraction, String message)? onProgress,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: server-backed extractor; pure-Dart on the device side.
      final result =
          await AudioDownloadService.instance.downloadAudioWithMetadata(
        url: url,
        outputDirectory: libraryDirectory,
        onProgress: (fraction) {
          // AudioDownloadService doesn't ship a default progress message
          // string, so synthesize one matching the existing UI text.
          onProgress?.call(
            fraction,
            'Downloading\u2026 ${(fraction * 100).toStringAsFixed(0)}%',
          );
        },
        onLog: (message) => onProgress?.call(0.0, message),
      );
      return SingleTrackDownloadResult(
        filePath: result.filePath,
        title: result.title,
        artist: result.artist,
      );
    }

    // Desktop: yt-dlp binary supports many sites natively, no server
    // roundtrip for the audio bytes themselves.
    final bin = BinaryService.instance.lastResolution;
    if (bin == null || !bin.ytDlpAvailable) {
      final detail = bin != null
          ? bin.errors.join(' ')
          : 'Binary resolution did not run.';
      throw StateError('yt-dlp is not available. $detail');
    }

    final filePath = await DownloadService.downloadUrlToMp3(
      url: url,
      outputDirectory: libraryDirectory,
      ytDlpExecutablePath: bin.ytDlpPath,
      onProgress: (p) => onProgress?.call(p.fraction, p.message),
    );

    return SingleTrackDownloadResult(filePath: filePath);
  }
}
