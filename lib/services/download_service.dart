import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'artwork_service.dart';
import 'binary_service.dart';

/// Progress update while yt-dlp is running (fraction + latest log line).
class DownloadProgress {
  /// Creates a progress snapshot.
  const DownloadProgress({
    required this.fraction,
    required this.message,
  });

  /// Approximate 0.0–1.0 progress (best-effort from yt-dlp stderr).
  final double fraction;

  /// Last meaningful line from yt-dlp output for UI.
  final String message;
}

/// Outcome of a desktop yt-dlp download.
class DownloadResult {
  /// Creates a desktop download result.
  const DownloadResult({
    required this.filePath,
    this.artworkPath,
  });

  /// Absolute path to the saved `.mp3`.
  final String filePath;

  /// Absolute path to the cover image saved next to the audio, or `null`
  /// when artwork could not be obtained (non-YouTube URL, network error).
  final String? artworkPath;
}

/// Runs `yt-dlp` as a child process to download audio.
///
/// Linux/Windows-only. Uses `-x --audio-format mp3 --audio-quality 0`
/// for cross-site MP3 transcoding (ffmpeg is required and resolved via
/// [BinaryService]).
class DownloadService {
  /// Hard cap so SSL/network stalls cannot leave the UI on "Starting…" forever.
  static const Duration ytDlpTimeout = Duration(minutes: 45);

  /// Backwards-compatible wrapper around [downloadUrlToMp3WithArtwork]
  /// that returns just the audio path.
  static Future<String> downloadUrlToMp3({
    required String url,
    required String outputDirectory,
    required String ytDlpExecutablePath,
    void Function(DownloadProgress p)? onProgress,
  }) async {
    final result = await downloadUrlToMp3WithArtwork(
      url: url,
      outputDirectory: outputDirectory,
      ytDlpExecutablePath: ytDlpExecutablePath,
      onProgress: onProgress,
    );
    return result.filePath;
  }

  /// Downloads audio from [url] into [outputDirectory] and returns the
  /// created audio path plus any cover image saved next to it.
  ///
  /// The file is `.mp3` (yt-dlp transcodes via ffmpeg).
  ///
  /// Throws [StateError], [ProcessException], or [TimeoutException] on
  /// audio failure. Artwork failures never throw — the result simply
  /// resolves with `artworkPath: null` and the UI falls back to the
  /// generic placeholder.
  ///
  /// [onProgress] receives stderr lines; [fraction] is heuristic based on
  /// `[download]` percentages when present.
  static Future<DownloadResult> downloadUrlToMp3WithArtwork({
    required String url,
    required String outputDirectory,
    required String ytDlpExecutablePath,
    void Function(DownloadProgress p)? onProgress,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(url, 'url', 'URL must not be empty');
    }
    if (!File(ytDlpExecutablePath).existsSync()) {
      // Tailor the recovery hint per OS — on Windows we ship the binary
      // in assets, on Linux we download it on first run.
      final hint = Platform.isLinux
          ? 'Restart Plamus to redownload yt-dlp, or place a yt-dlp '
              'binary at "$ytDlpExecutablePath".'
          : 'Place yt-dlp.exe in assets/bin/ and restart the app.';
      throw StateError('yt-dlp not found at "$ytDlpExecutablePath". $hint');
    }

    final outDir = Directory(outputDirectory);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    // Snapshot the directory BEFORE the download so we can identify the
    // file yt-dlp produced even when the "most recent .mp3" heuristic
    // would otherwise alias to a previously-downloaded track. This also
    // helps when a playlist contains a video that's already been
    // imported once: yt-dlp's default `--no-overwrites` skips the
    // download entirely, leaving the directory unchanged — without the
    // pre/post diff we'd silently re-register the wrong row.
    final beforeFiles = <String>{};
    try {
      await for (final entry in outDir.list(followLinks: false)) {
        if (entry is File &&
            p.extension(entry.path).toLowerCase() == '.mp3') {
          beforeFiles.add(entry.path);
        }
      }
    } catch (_) {
      // Listing failed (rare on first launch). Treat the directory as
      // empty — worst case we fall back to the legacy heuristic below.
    }

    final template = p.join(outputDirectory, '%(title)s.%(ext)s');

    // `--print after_move:filepath` writes the absolute on-disk path to
    // stdout once yt-dlp has finished post-processing. We parse it so
    // every per-track download in a playlist is unambiguous, even when
    // titles collide or the file already existed. Stdout was previously
    // discarded — keep `--no-warnings` on so other lines stay quiet.
    //
    // `--no-playlist` prevents accidental playlist expansion when a
    // watch URL happens to have a `list=` query parameter.
    final args = <String>[
      '--no-playlist',
      '--no-check-certificates',
      '--no-warnings',
      '-x',
      '--audio-format',
      'mp3',
      '--audio-quality',
      '0',
      '--print',
      'after_move:filepath',
      '-o',
      template,
      trimmed,
    ];

    Process? process;
    StreamSubscription<dynamic>? stderrSub;
    StreamSubscription<dynamic>? stdoutSub;

    try {
      process = await Process.start(
        ytDlpExecutablePath,
        args,
        runInShell: false,
        environment: Platform.environment,
      );

      final stderrLines = <String>[];
      final stdoutLines = <String>[];
      var lastFraction = 0.0;

      void handleStderr(String line) {
        final clean = line.trim();
        if (clean.isEmpty) return;
        stderrLines.add(clean);
        final pct = _tryParseDownloadPercent(clean);
        if (pct != null) {
          lastFraction = pct.clamp(0.0, 1.0);
        }
        onProgress?.call(
          DownloadProgress(fraction: lastFraction, message: clean),
        );
      }

      void handleStdout(String line) {
        final clean = line.trim();
        if (clean.isEmpty) return;
        stdoutLines.add(clean);
      }

      onProgress?.call(
        const DownloadProgress(
          fraction: 0.02,
          message: 'Starting download…',
        ),
      );

      stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            handleStdout,
            onError: (_) {},
            cancelOnError: false,
          );

      stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            handleStderr,
            onError: (_) {},
            cancelOnError: false,
          );

      late int exitCode;
      try {
        exitCode = await process.exitCode.timeout(
          ytDlpTimeout,
          onTimeout: () {
            process!.kill(ProcessSignal.sigterm);
            throw TimeoutException(
              'yt-dlp timed out after ${ytDlpTimeout.inMinutes} minutes. '
              'Often caused by SSL or network issues — try another network or VPN off.',
              ytDlpTimeout,
            );
          },
        );
      } on TimeoutException catch (e) {
        onProgress?.call(
          DownloadProgress(
            fraction: lastFraction,
            message: e.message ?? 'Timed out',
          ),
        );
        rethrow;
      }

      if (exitCode != 0) {
        final tail = stderrLines.length > 12
            ? stderrLines.sublist(stderrLines.length - 12)
            : stderrLines;
        throw ProcessException(
          ytDlpExecutablePath,
          args,
          'yt-dlp exited with code $exitCode.\n${tail.join('\n')}',
          exitCode,
        );
      }

      // Resolve the on-disk path in priority order:
      //   1. The path printed via `--print after_move:filepath` — this
      //      is what yt-dlp actually wrote to and survives playlist
      //      runs where titles collide or a prior import already
      //      registered a same-named file.
      //   2. New `.mp3` files appearing in the directory since the
      //      pre-download snapshot. Catches the corner case where
      //      `--print` printed nothing (very old yt-dlp, or a
      //      post-processor that skipped the move step).
      //   3. Legacy fallback: most recently modified `.mp3` in the
      //      directory.
      String? audioPath = _resolvePrintedFilepath(stdoutLines, outDir.path);

      if (audioPath == null) {
        final allFiles = await outDir
            .list(followLinks: false)
            .where(
              (e) => e is File && p.extension(e.path).toLowerCase() == '.mp3',
            )
            .cast<File>()
            .toList();
        if (allFiles.isEmpty) {
          throw StateError(
            'yt-dlp reported success but no .mp3 was found in '
            '"$outputDirectory".',
          );
        }
        final fresh =
            allFiles.where((f) => !beforeFiles.contains(f.path)).toList();
        if (fresh.length == 1) {
          audioPath = fresh.first.path;
        } else if (fresh.length > 1) {
          fresh.sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
          );
          audioPath = fresh.first.path;
        } else {
          // No new files — the source already existed on disk. We can
          // legitimately re-register it (LibraryService deduplicates
          // by file path), so fall through to the legacy "most recent"
          // heuristic.
          allFiles.sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
          );
          audioPath = allFiles.first.path;
        }
      }

      // Best-effort artwork download. Runs after yt-dlp succeeded, so
      // the user already has the audio on disk by this point — any
      // failure here resolves to `artworkPath: null` and never disrupts
      // the import.
      String? artworkPath;
      onProgress?.call(
        DownloadProgress(fraction: lastFraction, message: 'Saving artwork…'),
      );
      try {
        artworkPath = await ArtworkService.downloadArtworkForYoutube(
          sourceUrl: trimmed,
          audioFilePath: audioPath,
        );
      } catch (_) {
        // Artwork is decorative — never let it surface as a fatal error.
      }

      return DownloadResult(
        filePath: audioPath,
        artworkPath: artworkPath,
      );
    } catch (e, st) {
      if (process != null) {
        try {
          process.kill(ProcessSignal.sigterm);
        } catch (_) {}
      }
      if (e is TimeoutException || e is ProcessException || e is StateError) {
        rethrow;
      }
      throw StateError('Download failed: $e\n$st');
    } finally {
      await stderrSub?.cancel();
      await stdoutSub?.cancel();
    }
  }

  /// Parses strings like `[download]  45.2% of ...` into 0.452.
  static double? _tryParseDownloadPercent(String line) {
    final re = RegExp(r'\[download\]\s+(\d+\.?\d*)%');
    final m = re.firstMatch(line);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null) return null;
    return v / 100.0;
  }

  /// Walks [stdoutLines] backwards looking for a path that exists on
  /// disk under [outputDirectory] and ends in `.mp3`. yt-dlp prints
  /// non-path output (warnings, info messages) on stdout too when
  /// invoked with `--print`, so we skip anything that doesn't resolve
  /// to a real file. Walking from the end matches yt-dlp's own
  /// ordering — `after_move:filepath` is the last per-track print.
  static String? _resolvePrintedFilepath(
    List<String> stdoutLines,
    String outputDirectory,
  ) {
    final norm = p.normalize(outputDirectory);
    for (var i = stdoutLines.length - 1; i >= 0; i--) {
      final raw = stdoutLines[i].trim();
      if (raw.isEmpty) continue;
      if (p.extension(raw).toLowerCase() != '.mp3') continue;
      final candidate = p.isAbsolute(raw) ? raw : p.join(norm, raw);
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  /// Convenience: uses paths from [BinaryService.lastResolution].
  static Future<String> downloadWithBundledBinary({
    required String url,
    required String outputDirectory,
    void Function(DownloadProgress p)? onProgress,
  }) async {
    final res = BinaryService.instance.lastResolution;
    if (res == null || !res.ytDlpAvailable) {
      throw StateError(
        'yt-dlp is not available. Check binary extraction errors: '
        '${res?.errors.join(' ') ?? 'resolution not run'}',
      );
    }
    return downloadUrlToMp3(
      url: url,
      outputDirectory: outputDirectory,
      ytDlpExecutablePath: res.ytDlpPath,
      onProgress: onProgress,
    );
  }
}
