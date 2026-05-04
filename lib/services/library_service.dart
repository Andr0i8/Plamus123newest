import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../database/database_helper.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';
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
  /// [inLibrary] controls whether the new row is visible in the main
  /// library list. Pass `false` when importing directly into a playlist so
  /// the track only appears in that playlist (BUG 6). When the file is
  /// already indexed, [inLibrary] is ignored to avoid hiding tracks the
  /// user can already see.
  Future<int> registerTrackFile(
    String filePath, {
    String? artist,
    String? title,
    bool inLibrary = true,
  }) async {
    final f = File(filePath);
    if (!await f.exists()) {
      throw FileSystemException('Cannot register missing file', filePath);
    }
    final sqlite = await _db.database;
    final existing = await sqlite.query(
      'tracks',
      columns: ['id'],
      where: 'filePath = ?',
      whereArgs: [filePath],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return existing.first['id'] as int;
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

    await _db.updateTrack(
      track.copyWith(title: trimmed, filePath: targetPath),
    );
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
  Future<void> deleteTrack(TrackModel track, {bool deleteFile = true}) async {
    if (track.id == null) return;
    if (deleteFile) {
      final f = File(track.filePath);
      if (await f.exists()) {
        await f.delete();
      }
    }
    await _db.deleteTrack(track.id!);
    await refreshTracks();
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
