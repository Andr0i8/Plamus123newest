import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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

/// Runs `yt-dlp` as a child process to download and extract MP3 audio.
///
/// Uses flags `-x --audio-format mp3 --audio-quality 0` as specified for the
/// Plamus gutter engine. Requires [BinaryService] binaries to be available.
class DownloadService {
  /// Hard cap so SSL/network stalls cannot leave the UI on "Starting…" forever.
  static const Duration ytDlpTimeout = Duration(minutes: 45);

  /// Downloads audio from [url] into [outputDirectory] and returns the created
  /// `.mp3` path, or throws [StateError], [ProcessException], or [TimeoutException].
  ///
  /// [onProgress] receives stderr lines; [fraction] is heuristic based on
  /// `[download]` percentages when present.
  static Future<String> downloadUrlToMp3({
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
      // Tailor the recovery hint per OS — on Windows we ship the binary in
      // assets, on Linux we download it on first run, on macOS it's still
      // bundled the same way as Windows.
      final hint = Platform.isLinux
          ? 'Restart Plamus to redownload yt-dlp, or place a yt-dlp binary at "$ytDlpExecutablePath".'
          : 'Place yt-dlp.exe in assets/bin/ and restart the app.';
      throw StateError('yt-dlp not found at "$ytDlpExecutablePath". $hint');
    }

    final outDir = Directory(outputDirectory);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final template = p.join(outputDirectory, '%(title)s.%(ext)s');

    final args = <String>[
      '--no-playlist',
      '--no-check-certificates',
      '--no-warnings',
      '-x',
      '--audio-format',
      'mp3',
      '--audio-quality',
      '0',
      '-o',
      template,
      trimmed,
    ];

    Process? process;
    StreamSubscription<dynamic>? stderrSub;
    StreamSubscription<List<int>>? stdoutSub;

    try {
      process = await Process.start(
        ytDlpExecutablePath,
        args,
        runInShell: false,
        environment: {...Platform.environment},
      );

      final stderrLines = <String>[];
      var lastFraction = 0.0;

      void handleLine(String line) {
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

      onProgress?.call(
        const DownloadProgress(
          fraction: 0.02,
          message: 'Starting download…',
        ),
      );

      // Consume stdout so the process cannot block if the pipe fills.
      stdoutSub = process.stdout.listen(
        (_) {},
        onError: (_) {},
        cancelOnError: false,
      );

      stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            handleLine,
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

      final files = await outDir
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.mp3'))
          .cast<File>()
          .toList();

      if (files.isEmpty) {
        throw StateError(
          'yt-dlp reported success but no .mp3 was found in "$outputDirectory".',
        );
      }

      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      return files.first.path;
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
