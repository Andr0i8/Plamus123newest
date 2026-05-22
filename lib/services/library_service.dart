import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../database/database_helper.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';
import 'plamus_paths.dart';
import 'shell_service.dart';

/// Coordinates SQLite and filesystem operations for the music library UI.
class LibraryService extends ChangeNotifier {
  /// Creates the library service.
  LibraryService(this._db);

  final DatabaseHelper _db;

  List<TrackModel> _tracks = [];
  List<PlaylistModel> _playlists = [];

  /// Cached full library list.
  List<TrackModel> get tracks => List.unmodifiable(_tracks);

  /// Cached playlists.
  List<PlaylistModel> get playlists => List.unmodifiable(_playlists);

  /// Registers an existing audio file path in the library (no file copy).
  ///
  /// Use after yt-dlp writes an MP3 into the library folder. If the path is
  /// already indexed, returns the existing id.
  ///
  /// [artist] populates the artist column (falls back to "Unknown" when
  /// null/empty). [title] overrides the filename-derived display title
  /// when provided — useful when a YouTube extractor returned the original
  /// video title via `X-Track-Title`.
  ///
  /// [sourceUrl] stores the original YouTube URL for later sharing. Leave it
  /// null for local files and non-YouTube direct audio links.
  ///
  /// [artworkPath] points at a locally-saved cover image (typically a
  /// YouTube thumbnail) downloaded next to the audio file. Pass `null`
  /// when no artwork is available — the UI falls back to the placeholder.
  /// When the file is already indexed and no artwork was previously
  /// stored, the existing row is updated with [artworkPath] so re-imports
  /// can backfill missing covers.
  ///
  /// [inLibrary] controls whether the new row is visible in the main
  /// library list. Pass `false` when importing directly into a playlist so
  /// the track only appears in that playlist (BUG 6). When the file is
  /// already indexed, [inLibrary] is ignored to avoid hiding tracks the
  /// user can already see.
  Future<int> registerTrackFile(
    String filePath, {
    String? artist,
    String? title,
    String? sourceUrl,
    String? artworkPath,
    bool inLibrary = true,
  }) async {
    final f = File(filePath);
    if (!await f.exists()) {
      throw FileSystemException('Cannot register missing file', filePath);
    }
    final sqlite = await _db.database;
    final normalizedSourceUrl = _normalizeOptionalUrl(sourceUrl);
    final normalizedArtwork = _normalizeOptionalPath(artworkPath);
    final existing = await sqlite.query(
      'tracks',
      columns: ['id', 'sourceUrl', 'artworkPath'],
      where: 'filePath = ?',
      whereArgs: [filePath],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      final existingSource = _normalizeOptionalUrl(
        existing.first['sourceUrl'] as String?,
      );
      final existingArtwork = _normalizeOptionalPath(
        existing.first['artworkPath'] as String?,
      );
      final updates = <String, Object?>{};
      if (normalizedSourceUrl != null && existingSource == null) {
        updates['sourceUrl'] = normalizedSourceUrl;
      }
      // Backfill artwork for tracks that were imported before artwork
      // support landed (or where the previous fetch failed and the user
      // re-imported the same file).
      if (normalizedArtwork != null && existingArtwork == null) {
        updates['artworkPath'] = normalizedArtwork;
      }
      if (updates.isNotEmpty) {
        await sqlite.update(
          'tracks',
          updates,
          where: 'id = ?',
          whereArgs: [id],
        );
        await refreshTracks();
      }
      return id;
    }
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : p.basenameWithoutExtension(filePath);
    final resolvedArtist = (artist != null && artist.trim().isNotEmpty)
        ? artist.trim()
        : 'Unknown';
    final track = TrackModel(
      title: resolvedTitle,
      artist: resolvedArtist,
      filePath: filePath,
      sourceUrl: normalizedSourceUrl,
      artworkPath: normalizedArtwork,
      durationMs: 0,
      inLibrary: inLibrary,
      dateAdded: DateTime.now().toUtc().toIso8601String(),
    );
    final id = await _db.insertTrack(track);
    await refreshTracks();
    return id;
  }

  /// Loads tracks and playlists from disk.
  Future<void> refreshAll() async {
    _tracks = await _db.getAllTracks();
    _playlists = await _db.getAllPlaylists();
    notifyListeners();
  }

  /// Refreshes tracks only (e.g. after like toggle).
  Future<void> refreshTracks() async {
    _tracks = await _db.getAllTracks();
    notifyListeners();
  }

  /// Liked smart list.
  Future<List<TrackModel>> likedTracks() => _db.getLikedTracks();

  /// Recent history smart list.
  Future<List<TrackModel>> recentTracks() async {
    final entries = await _db.getRecentHistory(limit: 50);
    return entries.map((e) => e.track).toList();
  }

  /// Creates a new empty playlist and refreshes cache.
  Future<int> createPlaylist(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Playlist name must not be empty');
    }
    final pl = PlaylistModel(
      name: trimmed,
      dateCreated: DateTime.now().toUtc().toIso8601String(),
    );
    final id = await _db.insertPlaylist(pl);
    await refreshAll();
    return id;
  }

  /// Renames a user playlist.
  Future<void> renamePlaylist(int id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Playlist name must not be empty');
    }
    await _db.updatePlaylistName(id, trimmed);
    await refreshAll();
  }

  /// Deletes a playlist definition (tracks remain in library).
  Future<void> deletePlaylist(int id) async {
    await _db.deletePlaylist(id);
    await refreshAll();
  }

  /// Adds a library track to a playlist.
  Future<void> addTrackToPlaylist(int playlistId, int trackId) async {
    await _db.addTrackToPlaylist(playlistId, trackId);
    notifyListeners();
  }

  /// Removes a track from a playlist (the track itself remains in the
  /// library / on disk).
  Future<void> removeTrackFromPlaylist(int playlistId, int trackId) async {
    await _db.removeTrackFromPlaylist(playlistId, trackId);
    notifyListeners();
  }

  /// Toggles like and refreshes track cache.
  Future<void> toggleLike(TrackModel track) async {
    if (track.id == null) return;
    await _db.setTrackLiked(track.id!, !track.isLiked);
    await refreshTracks();
  }

  /// Updates title and renames the underlying file to match (Windows-safe).
  ///
  /// Throws [FileSystemException] if the rename fails (e.g. file in use).
  ///
  /// When the track has a sibling artwork file (`<basename>.jpg`) it is
  /// renamed alongside the audio so the cover image stays paired with
  /// the track row. Artwork rename failures are non-fatal — the audio
  /// file is the source of truth and we'd rather show the placeholder
  /// than fail the title edit because of a stale JPG.
  Future<void> renameTrackTitle(TrackModel track, String newTitle) async {
    if (track.id == null) {
      throw StateError('Cannot rename a track without id');
    }
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Title must not be empty');
    }

    final oldFile = File(track.filePath);
    if (!await oldFile.exists()) {
      throw FileSystemException('Track file missing', track.filePath);
    }

    final dir = p.dirname(track.filePath);
    final ext = p.extension(track.filePath);
    final sanitized = _sanitizeFileName(trimmed);
    var targetPath = p.join(dir, '$sanitized$ext');
    targetPath = await _ensureUniquePath(targetPath, oldFile.path);

    if (targetPath != oldFile.path) {
      await oldFile.rename(targetPath);
    }

    String? newArtworkPath = track.artworkPath;
    final oldArtworkPath = track.artworkPath;
    if (oldArtworkPath != null && oldArtworkPath.isNotEmpty) {
      try {
        final oldArtwork = File(oldArtworkPath);
        if (await oldArtwork.exists()) {
          final artworkExt = p.extension(oldArtworkPath);
          final desired = p.join(
            p.dirname(targetPath),
            '${p.basenameWithoutExtension(targetPath)}$artworkExt',
          );
          // Only move when source != destination to avoid a
          // self-overwrite.
          if (desired != oldArtworkPath) {
            final unique = await _ensureUniquePath(desired, oldArtworkPath);
            await oldArtwork.rename(unique);
            newArtworkPath = unique;
          }
        } else {
          // Artwork file is gone; clear the column so the UI falls back
          // to the placeholder instead of trying to render a missing file.
          newArtworkPath = null;
        }
      } catch (e) {
        // Non-fatal — fall back to clearing the artwork reference rather
        // than blocking the rename.
        newArtworkPath = null;
      }
    }

    final updated = track.copyWith(title: trimmed, filePath: targetPath);
    final finalTrack = newArtworkPath == null
        ? updated.copyWith(clearArtwork: true)
        : updated.copyWith(artworkPath: newArtworkPath);
    await _db.updateTrack(finalTrack);
    await refreshTracks();
  }

  /// Copies the track file to a user-chosen path (Export to…).
  Future<void> exportTrackTo(TrackModel track) async {
    final f = File(track.filePath);
    if (!await f.exists()) {
      throw FileSystemException('Cannot export missing file', track.filePath);
    }
    final name = p.basename(track.filePath);
    final out = await FilePicker.platform.saveFile(
      dialogTitle: 'Export track',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: [p.extension(name).replaceFirst('.', '')],
    );
    if (out == null) return;
    final dest = out.toLowerCase().endsWith(p.extension(name).toLowerCase())
        ? out
        : '$out${p.extension(name)}';
    await f.copy(dest);
  }

  /// Opens the system file manager focused on the track file.
  ///
  /// Routes through [ShellService.showInFolder] which uses Explorer on
  /// Windows, `xdg-open` on Linux, and Finder (`open -R`) on macOS.
  Future<void> revealTrackInExplorer(TrackModel track) async {
    await ShellService.showInFolder(track.filePath);
  }

  /// Removes DB row and optionally deletes the file from the library folder.
  ///
  /// When [deleteFile] is true the sibling artwork file (if any) is also
  /// removed so the library directory doesn't accumulate orphaned cover
  /// images. Artwork deletion failures are silently ignored — the audio
  /// is the source of truth and we don't want a stale JPG to block the
  /// remove action.
  Future<void> deleteTrack(TrackModel track, {bool deleteFile = true}) async {
    if (track.id == null) return;
    if (deleteFile) {
      final f = File(track.filePath);
      if (await f.exists()) {
        await f.delete();
      }
      final artworkPath = track.artworkPath;
      if (artworkPath != null && artworkPath.isNotEmpty) {
        try {
          final artFile = File(artworkPath);
          if (await artFile.exists()) {
            await artFile.delete();
          }
        } catch (_) {
          // Leave behind a stray JPG rather than fail the delete.
        }
      }
    }
    await _db.deleteTrack(track.id!);
    await refreshTracks();
  }

  /// Wipes every row from the library tables AND deletes every file
  /// inside the on-disk music library directory. Used by the "Clear
  /// all data" Settings action.
  ///
  /// Order matters:
  ///   1. Empty the database first so the rest of the app sees the
  ///      now-orphaned files as gone even if a per-file delete fails.
  ///   2. Walk the library directory and remove every entry. Per-file
  ///      failures (locked file, permissions, etc.) are swallowed so
  ///      one stubborn file can't strand the rest — the user gets a
  ///      clean DB regardless of filesystem state.
  ///   3. Refresh the in-memory caches so every widget watching
  ///      [LibraryService] repaints with the empty state.
  ///
  /// The caller is responsible for stopping audio playback BEFORE
  /// calling this — on Windows, the file currently playing is locked
  /// by the audio engine and can't be removed until [AudioPlayerService.stop]
  /// has released the handle.
  Future<void> clearAllData() async {
    await _db.wipeAllData();

    try {
      final libPath = await PlamusPaths.musicLibraryDirectory();
      final libDir = Directory(libPath);
      if (await libDir.exists()) {
        await for (final entry in libDir.list(followLinks: false)) {
          try {
            if (entry is File) {
              await entry.delete();
            } else if (entry is Directory) {
              await entry.delete(recursive: true);
            }
          } catch (e) {
            // Best-effort: ignore per-file failures so the rest still
            // gets cleaned up. The DB rows are gone regardless.
            debugPrint(
              'LibraryService.clearAllData: could not delete ${entry.path}: $e',
            );
          }
        }
      }
    } catch (e) {
      debugPrint(
        'LibraryService.clearAllData: could not enumerate library dir: $e',
      );
    }

    await refreshAll();
  }

  static String? _normalizeOptionalUrl(String? raw) {
    final value = raw?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static String? _normalizeOptionalPath(String? raw) {
    final value = raw?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static String _sanitizeFileName(String raw) {
    const bad = r'<>:"/\|?*';
    var s = raw;
    for (final c in bad.split('')) {
      s = s.replaceAll(c, '_');
    }
    s = s.trim();
    return s.isEmpty ? 'track' : s;
  }

  static Future<String> _ensureUniquePath(
    String desiredPath,
    String originalPath,
  ) async {
    if (desiredPath == originalPath) return desiredPath;
    if (!await File(desiredPath).exists()) return desiredPath;
    final dir = p.dirname(desiredPath);
    final base = p.basenameWithoutExtension(desiredPath);
    final ext = p.extension(desiredPath);
    for (var i = 1; i < 10000; i++) {
      final candidate = p.join(dir, '${base}_$i$ext');
      if (!await File(candidate).exists()) return candidate;
    }
    throw StateError('Could not find unique name for $desiredPath');
  }
}
