import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/database_helper.dart';
import '../models/track_model.dart';
import 'binary_service.dart';

/// Handles local file import: copy audio files into the library folder.
///
/// On Android/iOS, only audio files are supported (no video transcoding).
/// On desktop, video containers are passed through ffmpeg to extract audio.
class MediaIngestService {
  MediaIngestService._();

  static final MediaIngestService instance = MediaIngestService._();

  /// Extensions treated as audio-only (direct copy, no transcoding).
  static const Set<String> audioExtensions = {
    '.mp3',
    '.wav',
    '.flac',
    '.m4a',
    '.aac',
    '.ogg',
    '.opus',
    '.webm',
    '.wma',
  };

  /// Extensions treated as video; audio extraction requires ffmpeg (desktop only).
  static const Set<String> videoExtensions = {
    '.mp4',
    '.mkv',
    '.mov',
    '.avi',
  };

  /// Imports [sourcePath] into library, returns final audio path.
  Future<String> ingestFile(
    String sourcePath, {
    void Function(String message)? onLog,
  }) async {
    final libraryDirectory = await _getLibraryDirectory();
    return ingestLocalFile(
      sourcePath: sourcePath,
      libraryDirectory: libraryDirectory,
      onLog: onLog,
    );
  }

  Future<String> _getLibraryDirectory() async {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData == null) throw StateError('APPDATA not found');
      return p.join(appData, 'Plamus', 'library');
    } else if (Platform.isLinux) {
      // Match PlamusPaths.applicationSupportDirectory() — lowercase to follow
      // the XDG convention and the documented `~/.local/share/plamus/` spec.
      final xdg = Platform.environment['XDG_DATA_HOME'];
      final home = Platform.environment['HOME'];
      final base = (xdg != null && xdg.isNotEmpty)
          ? xdg
          : (home != null && home.isNotEmpty
              ? p.join(home, '.local', 'share')
              : null);
      if (base == null) {
        throw StateError('HOME or XDG_DATA_HOME not set');
      }
      return p.join(base, 'plamus', 'library');
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home == null) throw StateError('HOME not found');
      return p.join(
          home, 'Library', 'Application Support', 'Plamus', 'library');
    }
    // Android/iOS: let callers use PlamusPaths instead.
    throw UnsupportedError('Use PlamusPaths.musicLibraryDirectory() on mobile');
  }

  /// Imports [sourcePath] into [libraryDirectory], returns final audio path.
  static Future<String> ingestLocalFile({
    required String sourcePath,
    required String libraryDirectory,
    void Function(String message)? onLog,
  }) async {
    final src = File(sourcePath);
    if (!await src.exists()) {
      throw FileSystemException('Source file does not exist', sourcePath);
    }

    final ext = p.extension(sourcePath).toLowerCase();
    final libDir = Directory(libraryDirectory);
    if (!await libDir.exists()) {
      await libDir.create(recursive: true);
    }

    if (audioExtensions.contains(ext)) {
      onLog?.call('Copying audio into library\u2026');
      return _copyAudioToLibrary(src, libDir, ext);
    }

    if (videoExtensions.contains(ext)) {
      if (Platform.isAndroid || Platform.isIOS) {
        throw UnsupportedError(
          'Video file import is not supported on mobile. '
          'Please select an audio file (.mp3, .m4a, .flac, .ogg, etc.) '
          'or use the URL download for YouTube links.',
        );
      }
      onLog?.call('Extracting audio from video with ffmpeg\u2026');
      return _extractAudioWithFfmpeg(
        videoFile: src,
        libraryDir: libDir,
        onLog: onLog,
      );
    }

    throw UnsupportedError(
      'Unsupported file type "$ext". Use MP3, M4A, FLAC, OGG, WAV, or '
      'other common audio containers.',
    );
  }

  /// Copies [src] into [libDir] with a unique file name if needed.
  static Future<String> _copyAudioToLibrary(
    File src,
    Directory libDir,
    String ext,
  ) async {
    final base = p.basenameWithoutExtension(src.path);
    var target = File(p.join(libDir.path, '$base$ext'));
    target = File(await _uniquePath(target.path));
    await src.copy(target.path);
    return target.path;
  }

  /// Runs ffmpeg to encode audio to high-quality MP3 (VBR q 0). Desktop only.
  static Future<String> _extractAudioWithFfmpeg({
    required File videoFile,
    required Directory libraryDir,
    void Function(String message)? onLog,
  }) async {
    final res = BinaryService.instance.lastResolution;
    if (res == null || !res.ffmpegAvailable) {
      // Different recovery story per OS — on Linux ffmpeg comes from the
      // package manager, on Windows/macOS it ships as an asset.
      final hint = Platform.isLinux
          ? 'Install ffmpeg via your package manager '
              '(Arch: sudo pacman -S ffmpeg, Ubuntu/Debian: sudo apt install ffmpeg).'
          : 'Add ffmpeg.exe to assets/bin/ and restart.';
      throw StateError(
        'ffmpeg is not available. $hint '
        '${res?.errors.join(' ') ?? ''}',
      );
    }

    final base = p.basenameWithoutExtension(videoFile.path);
    var outPath = p.join(libraryDir.path, '$base.mp3');
    outPath = await _uniquePath(outPath);

    final args = <String>[
      '-y',
      '-i',
      videoFile.path,
      '-vn',
      '-codec:a',
      'libmp3lame',
      '-q:a',
      '0',
      outPath,
    ];

    onLog?.call('ffmpeg ${args.join(' ')}');

    final result = await Process.run(
      res.ffmpegPath,
      args,
      runInShell: false,
      environment: {...Platform.environment},
    );

    if (result.exitCode != 0) {
      final err = result.stderr.toString().trim();
      final out = result.stdout.toString().trim();
      throw ProcessException(
        res.ffmpegPath,
        args,
        'ffmpeg failed: ${err.isNotEmpty ? err : out}',
        result.exitCode,
      );
    }

    final outFile = File(outPath);
    if (!await outFile.exists()) {
      throw StateError('ffmpeg reported success but output missing: $outPath');
    }
    return outPath;
  }

  /// If [path] exists, appends _1, _2, ... before the extension.
  static Future<String> _uniquePath(String path) async {
    if (!await File(path).exists()) return path;
    final dir = p.dirname(path);
    final base = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    for (var i = 1; i < 10000; i++) {
      final candidate = p.join(dir, '${base}_$i$ext');
      if (!await File(candidate).exists()) return candidate;
    }
    throw StateError('Could not allocate unique path near $path');
  }

  /// Builds a [TrackModel] row for database insertion.
  static Future<TrackModel> buildTrackRow({
    required String filePath,
    required String title,
    String artist = 'Unknown',
    int durationMs = 0,
    bool inLibrary = true,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    return TrackModel(
      title: title,
      artist: artist,
      filePath: filePath,
      durationMs: durationMs,
      inLibrary: inLibrary,
      dateAdded: now,
    );
  }

  /// Inserts a new track after ingest if [filePath] is not already registered.
  ///
  /// [inLibrary] controls whether the new row appears in the main library
  /// view. Pass `false` when ingesting directly into a specific playlist
  /// (BUG 6) so the track is reachable only from that playlist.
  static Future<int> ingestAndRegister({
    required String sourcePath,
    required String libraryDirectory,
    void Function(String message)? onLog,
    bool inLibrary = true,
  }) async {
    final path = await ingestLocalFile(
      sourcePath: sourcePath,
      libraryDirectory: libraryDirectory,
      onLog: onLog,
    );

    final helper = DatabaseHelper.instance;
    final sqlite = await helper.database;
    final existing = await sqlite.query(
      'tracks',
      columns: ['id'],
      where: 'filePath = ?',
      whereArgs: [path],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return existing.first['id'] as int;
    }

    final title = p.basenameWithoutExtension(path);
    final track = await buildTrackRow(
      filePath: path,
      title: title,
      inLibrary: inLibrary,
    );
    return helper.insertTrack(track);
  }
}
