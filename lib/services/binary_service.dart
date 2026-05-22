import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError, debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'plamus_paths.dart';

/// Resolved paths to external CLI tools used by Plamus.
///
/// [ytDlpPath] and [ffmpegPath] point to executables on disk after
/// [BinaryService.ensureBinariesExtracted] runs. [errors] lists
/// human-readable problems (e.g. missing asset, no network) without
/// throwing from the initializer so the rest of the app still starts.
class BinaryResolution {
  /// Creates a resolution result.
  const BinaryResolution({
    required this.ytDlpPath,
    required this.ffmpegPath,
    required this.ytDlpAvailable,
    required this.ffmpegAvailable,
    this.errors = const [],
  });

  /// Absolute path where `yt-dlp` (or `yt-dlp.exe`) should live (may be missing).
  final String ytDlpPath;

  /// Absolute path where `ffmpeg` (or `ffmpeg.exe`) should live (may be missing).
  final String ffmpegPath;

  /// True when [ytDlpPath] exists and looks like a real executable.
  final bool ytDlpAvailable;

  /// True when [ffmpegPath] exists and looks like a real executable.
  final bool ffmpegAvailable;

  /// Non-fatal extraction or environment issues for UI messaging.
  final List<String> errors;
}

/// Resolves CLI tools (`yt-dlp`, `ffmpeg`) needed for desktop builds.
///
/// **Windows:** extracts bundled `yt-dlp.exe` and `ffmpeg.exe` from
/// Flutter assets into the per-user application support directory.
/// Assets must be declared under `assets/bin/` in `pubspec.yaml`.
///
/// **Linux:** downloads the latest static `yt-dlp` build from GitHub on
/// first run into `~/.local/share/plamus/bin/` and `chmod +x`'s it.
/// ffmpeg is resolved against the system `PATH` (`which ffmpeg`); if
/// missing, [BinaryResolution.errors] tells the user to install it via
/// their package manager.
///
/// If any binary is absent, the app still starts and
/// [BinaryResolution.errors] explains what is missing.
class BinaryService {
  BinaryService._();

  static final BinaryService instance = BinaryService._();

  static const String _assetYtDlpWin = 'assets/bin/yt-dlp.exe';
  static const String _assetFfmpegWin = 'assets/bin/ffmpeg.exe';

  /// Source for the static Linux yt-dlp build. The
  /// `latest/download/yt-dlp` URL redirects to whichever release is
  /// current; `Client.send` follows redirects up to
  /// [http.Request.maxRedirects].
  static const String _ytDlpLinuxUrl =
      'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp';

  /// Cap for the yt-dlp download — we don't want to hang the splash forever.
  static const Duration _downloadTimeout = Duration(minutes: 5);

  BinaryResolution? _cached;

  /// Last successful or attempted resolution (null until
  /// [ensureBinariesExtracted]).
  BinaryResolution? get lastResolution => _cached;

  /// Resolves binaries for the current platform.
  ///
  /// Safe to call on every launch: existing on-disk binaries are reused
  /// and only redownloaded / rewritten when they are missing or look
  /// invalid.
  Future<BinaryResolution> ensureBinariesExtracted() async {
    if (Platform.isLinux) {
      return _cached = await _resolveLinux();
    }
    if (Platform.isWindows) {
      return _cached = await _resolveBundledAssets();
    }
    // Plamus is desktop-only (Linux + Windows). Other platforms get an
    // empty resolution and the UI surfaces the errors via the import
    // panel banner.
    return _cached = const BinaryResolution(
      ytDlpPath: '',
      ffmpegPath: '',
      ytDlpAvailable: false,
      ffmpegAvailable: false,
      errors: [
        'Plamus is built for Linux and Windows only.',
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Windows: extract bundled assets
  // ---------------------------------------------------------------------------

  Future<BinaryResolution> _resolveBundledAssets() async {
    final errors = <String>[];
    try {
      final supportPath = await PlamusPaths.applicationSupportDirectory();
      final binDir = Directory(p.join(supportPath, 'bin'));
      if (!await binDir.exists()) {
        await binDir.create(recursive: true);
      }

      final ytTarget = File(p.join(binDir.path, 'yt-dlp.exe'));
      final ffTarget = File(p.join(binDir.path, 'ffmpeg.exe'));

      await _materializeAssetExecutable(
        assetPath: _assetYtDlpWin,
        target: ytTarget,
        label: 'yt-dlp',
        errors: errors,
      );
      await _materializeAssetExecutable(
        assetPath: _assetFfmpegWin,
        target: ffTarget,
        label: 'ffmpeg',
        errors: errors,
      );

      final ytOk = await _isPlausibleExecutable(ytTarget);
      final ffOk = await _isPlausibleExecutable(ffTarget);

      if (!ytOk) {
        errors.add(
          'yt-dlp.exe is missing or invalid. Add assets/bin/yt-dlp.exe and rebuild.',
        );
      }
      if (!ffOk) {
        errors.add(
          'ffmpeg.exe is missing or invalid. Add assets/bin/ffmpeg.exe and rebuild.',
        );
      }

      return BinaryResolution(
        ytDlpPath: ytTarget.path,
        ffmpegPath: ffTarget.path,
        ytDlpAvailable: ytOk,
        ffmpegAvailable: ffOk,
        errors: List.unmodifiable(errors),
      );
    } catch (e, st) {
      errors.add('Binary extraction failed: $e');
      assert(() {
        // ignore: avoid_print
        print(st);
        return true;
      }());
      return BinaryResolution(
        ytDlpPath: '',
        ffmpegPath: '',
        ytDlpAvailable: false,
        ffmpegAvailable: false,
        errors: List.unmodifiable(errors),
      );
    }
  }

  /// Writes [assetPath] to [target] when the asset exists and size differs.
  static Future<void> _materializeAssetExecutable({
    required String assetPath,
    required File target,
    required String label,
    required List<String> errors,
  }) async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      const minExeBytes = 4096;
      if (bytes.length < minExeBytes) {
        errors.add(
          '$label: bundled asset at $assetPath is too small (${bytes.length} B) — '
          'replace with a real Windows build.',
        );
        return;
      }
      if (await target.exists() && await target.length() == bytes.length) {
        return;
      }
      await target.writeAsBytes(bytes, flush: true);
    } on FileSystemException catch (e) {
      errors.add(
        '$label: cannot write "${target.path}" (${e.message}). '
        'Check disk space and that Plamus may write to application support (AppData).',
      );
    } on FlutterError catch (e) {
      errors.add(
        '$label: could not load $assetPath (${e.message}). '
        'Ensure the file exists under assets/bin/ and flutter pub get was run.',
      );
    } catch (e) {
      errors.add('$label: unexpected error loading $assetPath: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Linux: download yt-dlp + use system ffmpeg
  // ---------------------------------------------------------------------------

  Future<BinaryResolution> _resolveLinux() async {
    final errors = <String>[];
    String ytPath = '';
    bool ytOk = false;

    try {
      final supportPath = await PlamusPaths.applicationSupportDirectory();
      final binDir = Directory(p.join(supportPath, 'bin'));
      if (!await binDir.exists()) {
        await binDir.create(recursive: true);
      }

      final ytTarget = File(p.join(binDir.path, 'yt-dlp'));
      ytPath = ytTarget.path;

      ytOk = await _isPlausibleExecutable(ytTarget);
      if (!ytOk) {
        debugPrint('BinaryService: downloading yt-dlp to ${ytTarget.path}');
        try {
          await _downloadFile(
            url: _ytDlpLinuxUrl,
            target: ytTarget,
            timeout: _downloadTimeout,
          );
          await _chmodPlusX(ytTarget.path);
          ytOk = await _isPlausibleExecutable(ytTarget);
          if (!ytOk) {
            errors.add(
              'yt-dlp downloaded but does not look like a valid executable '
              '(${await ytTarget.exists() ? '${await ytTarget.length()} B' : 'missing'}).',
            );
          }
        } catch (e) {
          errors.add(
            'Could not download yt-dlp from $_ytDlpLinuxUrl ($e). '
            'Check your internet connection or place a yt-dlp binary at '
            '"${ytTarget.path}" manually.',
          );
        }
      } else {
        // Re-apply chmod +x in case the file lost its execute bit (e.g. a
        // backup/restore tool stripped permissions).
        await _chmodPlusX(ytTarget.path);
      }
    } catch (e, st) {
      errors.add('Could not prepare yt-dlp on Linux: $e');
      assert(() {
        // ignore: avoid_print
        print(st);
        return true;
      }());
    }

    final ffmpegResolved = await _findSystemFfmpeg();
    final ffPath = ffmpegResolved ?? '';
    final ffOk = ffmpegResolved != null;
    if (!ffOk) {
      errors.add(
        'ffmpeg is not installed. Install it with your package manager:\n'
        '  Arch: sudo pacman -S ffmpeg\n'
        '  Ubuntu/Debian: sudo apt install ffmpeg\n'
        '  Fedora: sudo dnf install ffmpeg',
      );
    }

    return BinaryResolution(
      ytDlpPath: ytPath,
      ffmpegPath: ffPath,
      ytDlpAvailable: ytOk,
      ffmpegAvailable: ffOk,
      errors: List.unmodifiable(errors),
    );
  }

  /// Resolves an `ffmpeg` executable on `PATH`. Returns `null` if not found.
  static Future<String?> _findSystemFfmpeg() async {
    try {
      final result = await Process.run('which', ['ffmpeg']);
      if (result.exitCode == 0) {
        final out = (result.stdout as Object?).toString().trim();
        if (out.isNotEmpty && await File(out).exists()) {
          return out;
        }
      }
    } catch (_) {
      // `which` itself missing — extremely rare on Linux but not fatal.
    }
    return null;
  }

  /// Streams [url] to [target] with redirect following and a hard [timeout].
  static Future<void> _downloadFile({
    required String url,
    required File target,
    required Duration timeout,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 5;
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode} from $url',
          uri: Uri.parse(url),
        );
      }
      // Write to a temp file first so a partial download never replaces the
      // existing binary.
      final tmp = File('${target.path}.part');
      if (await tmp.exists()) await tmp.delete();
      final sink = tmp.openWrite();
      try {
        await response.stream.pipe(sink);
      } catch (e) {
        await sink.close().catchError((_) {});
        if (await tmp.exists()) await tmp.delete();
        rethrow;
      }
      // pipe() closes the sink when the stream completes successfully.
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } finally {
      client.close();
    }
  }

  /// Best-effort `chmod +x` on POSIX systems. Silently skips on Windows.
  static Future<void> _chmodPlusX(String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['+x', path]);
    } catch (e) {
      debugPrint('BinaryService: chmod +x failed for $path: $e');
    }
  }

  /// True if file exists and is larger than a trivial placeholder.
  static Future<bool> _isPlausibleExecutable(File f) async {
    if (!await f.exists()) return false;
    final len = await f.length();
    return len > 4096;
  }
}
