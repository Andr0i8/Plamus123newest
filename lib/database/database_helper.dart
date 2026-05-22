import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/history_entry.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';

/// SQLite access layer for Plamus (tracks, playlists, playlist_tracks, history).
///
/// Desktop-only: Initialize FFI in `main()` before opening the DB:
/// `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;`
class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static const String _dbName = 'plamus.db';

  /// SQLite schema version.
  ///
  /// Version history:
  ///   * 1 — initial schema (tracks, playlists, playlist_tracks, history).
  ///   * 2 — added `tracks.inLibrary INTEGER NOT NULL DEFAULT 1` so we can
  ///         add tracks directly to a playlist without surfacing them in
  ///         the main library view (`getAllTracks` now filters on this).
  ///   * 3 — added nullable `tracks.sourceUrl` to preserve the original
  ///         YouTube URL for sharing downloaded tracks.
  ///   * 4 — added nullable `tracks.artworkPath` so the UI can render
  ///         locally-saved cover art (typically a YouTube thumbnail
  ///         downloaded next to the audio file). Existing rows leave the
  ///         column NULL and the UI keeps showing the placeholder for
  ///         them — there's no destructive migration.
  static const int _dbVersion = 4;

  Database? _db;

  /// Opens (or returns) the singleton database connection.
  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, _dbName);

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onOpen: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createTables,
        onUpgrade: _upgrade,
      ),
    );
  }

  /// Schema migrations between [_dbVersion] versions.
  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 → v2: add inLibrary flag for "playlist-only" tracks (BUG 6).
      // Existing rows default to 1 so the user's current library is
      // unchanged after the upgrade.
      await db.execute(
        'ALTER TABLE tracks ADD COLUMN inLibrary INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldVersion < 3) {
      // v2 → v3: store the original YouTube URL for downloaded tracks.
      // Nullable so existing local/imported rows remain valid.
      await db.execute('ALTER TABLE tracks ADD COLUMN sourceUrl TEXT');
    }
    if (oldVersion < 4) {
      // v3 → v4: store the absolute path of a locally-saved cover image.
      // Nullable: existing rows that pre-date artwork support fall back
      // to the generic placeholder — no destructive migration.
      await db.execute('ALTER TABLE tracks ADD COLUMN artworkPath TEXT');
    }
  }

  Future<void> _createTables(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tracks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        filePath TEXT NOT NULL UNIQUE,
        sourceUrl TEXT,
        artworkPath TEXT,
        durationMs INTEGER NOT NULL DEFAULT 0,
        isLiked INTEGER NOT NULL DEFAULT 0,
        inLibrary INTEGER NOT NULL DEFAULT 1,
        dateAdded TEXT NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        dateCreated TEXT NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE playlist_tracks (
        playlistId INTEGER NOT NULL,
        trackId INTEGER NOT NULL,
        position INTEGER NOT NULL,
        PRIMARY KEY (playlistId, trackId),
        FOREIGN KEY (playlistId) REFERENCES playlists (id) ON DELETE CASCADE,
        FOREIGN KEY (trackId) REFERENCES tracks (id) ON DELETE CASCADE
      );
    ''');
    await db.execute('''
      CREATE TABLE history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        trackId INTEGER NOT NULL,
        playedAt TEXT NOT NULL,
        FOREIGN KEY (trackId) REFERENCES tracks (id) ON DELETE CASCADE
      );
    ''');
    await db.execute(
      'CREATE INDEX idx_history_playedAt ON history (playedAt DESC);',
    );
    await db.execute(
      'CREATE INDEX idx_playlist_tracks_order ON playlist_tracks (playlistId, position);',
    );
  }

  // --- Tracks ---

  /// Inserts a track and returns the new row id.
  Future<int> insertTrack(TrackModel track) async {
    final db = await database;
    return db.insert('tracks', track.toMap()..remove('id'));
  }

  /// Returns every track that should appear in the main library, ordered
  /// by date added (newest first).
  ///
  /// Tracks marked `inLibrary = 0` are hidden — those were imported
  /// directly into a specific playlist (BUG 6) and intentionally don't
  /// appear in the global library.
  Future<List<TrackModel>> getAllTracks() async {
    final db = await database;
    final rows = await db.query(
      'tracks',
      where: 'inLibrary = 1',
      orderBy: 'dateAdded DESC',
    );
    return rows.map(TrackModel.fromMap).toList();
  }

  /// Loads a single track by primary key, or null if missing.
  Future<TrackModel?> getTrackById(int id) async {
    final db = await database;
    final rows = await db.query('tracks', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return TrackModel.fromMap(rows.first);
  }

  /// Updates editable metadata and flags for an existing track.
  Future<int> updateTrack(TrackModel track) async {
    if (track.id == null) {
      throw ArgumentError('updateTrack requires a non-null track.id');
    }
    final db = await database;
    final map = track.toMap()..remove('id');
    return db.update(
      'tracks',
      map,
      where: 'id = ?',
      whereArgs: [track.id],
    );
  }

  /// Removes a track and dependent rows (playlist links, history).
  Future<int> deleteTrack(int id) async {
    final db = await database;
    return db.delete('tracks', where: 'id = ?', whereArgs: [id]);
  }

  /// Smart list: tracks marked as liked.
  Future<List<TrackModel>> getLikedTracks() async {
    final db = await database;
    final rows = await db.query(
      'tracks',
      where: 'isLiked = 1',
      orderBy: 'dateAdded DESC',
    );
    return rows.map(TrackModel.fromMap).toList();
  }

  /// Toggles like state and persists it.
  Future<void> setTrackLiked(int trackId, bool liked) async {
    final db = await database;
    await db.update(
      'tracks',
      {'isLiked': liked ? 1 : 0},
      where: 'id = ?',
      whereArgs: [trackId],
    );
  }

  // --- Playlists ---

  /// Creates a playlist and returns its id.
  Future<int> insertPlaylist(PlaylistModel playlist) async {
    final db = await database;
    return db.insert('playlists', playlist.toMap()..remove('id'));
  }

  Future<List<PlaylistModel>> getAllPlaylists() async {
    final db = await database;
    final rows = await db.query('playlists', orderBy: 'dateCreated DESC');
    return rows.map(PlaylistModel.fromMap).toList();
  }

  Future<PlaylistModel?> getPlaylistById(int id) async {
    final db = await database;
    final rows = await db.query('playlists', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return PlaylistModel.fromMap(rows.first);
  }

  /// Renames a playlist.
  Future<int> updatePlaylistName(int id, String name) async {
    final db = await database;
    return db.update(
      'playlists',
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Deletes playlist and its `playlist_tracks` rows (FK CASCADE).
  Future<int> deletePlaylist(int id) async {
    final db = await database;
    return db.delete('playlists', where: 'id = ?', whereArgs: [id]);
  }

  // --- Playlist tracks ---

  /// Ordered tracks for a playlist.
  Future<List<TrackModel>> getTracksForPlaylist(int playlistId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT t.* FROM tracks t
      INNER JOIN playlist_tracks pt ON pt.trackId = t.id
      WHERE pt.playlistId = ?
      ORDER BY pt.position ASC
      ''',
      [playlistId],
    );
    return rows.map(TrackModel.fromMap).toList();
  }

  /// Appends a track at the end of the playlist if not already present.
  Future<void> addTrackToPlaylist(int playlistId, int trackId) async {
    final db = await database;
    final dup = await db.query(
      'playlist_tracks',
      where: 'playlistId = ? AND trackId = ?',
      whereArgs: [playlistId, trackId],
      limit: 1,
    );
    if (dup.isNotEmpty) return;

    final existing = await db.rawQuery(
      'SELECT MAX(position) as m FROM playlist_tracks WHERE playlistId = ?',
      [playlistId],
    );
    final max = existing.first['m'] as int?;
    final next = (max ?? -1) + 1;
    await db.insert('playlist_tracks', {
      'playlistId': playlistId,
      'trackId': trackId,
      'position': next,
    });
  }

  /// Removes a track from a playlist only (does not delete the track file/row).
  Future<void> removeTrackFromPlaylist(int playlistId, int trackId) async {
    final db = await database;
    await db.delete(
      'playlist_tracks',
      where: 'playlistId = ? AND trackId = ?',
      whereArgs: [playlistId, trackId],
    );
  }

  // --- History (last 50) ---

  /// Records a play and trims history to the 50 most recent events.
  Future<void> recordPlay(int trackId) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('history', {'trackId': trackId, 'playedAt': now});

    await db.rawDelete('''
      DELETE FROM history WHERE id IN (
        SELECT id FROM (
          SELECT id FROM history ORDER BY playedAt DESC LIMIT -1 OFFSET 50
        )
      );
    ''');
  }

  /// Smart list: up to 50 most recently played tracks (distinct by latest play).
  Future<List<HistoryEntry>> getRecentHistory({int limit = 50}) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT h.playedAt AS playedAt, t.*
      FROM history h
      INNER JOIN tracks t ON t.id = h.trackId
      ORDER BY h.playedAt DESC
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map((m) {
      final playedAt = m['playedAt'] as String? ?? '';
      final trackMap = Map<String, Object?>.from(m)..remove('playedAt');
      return HistoryEntry(
        track: TrackModel.fromMap(trackMap),
        playedAt: playedAt,
      );
    }).toList();
  }

  /// Clears all history entries.
  Future<void> clearHistory() async {
    final db = await database;
    await db.delete('history');
  }

  /// Removes all history entries for a specific track (does not delete the track itself).
  Future<void> removeTrackFromHistory(int trackId) async {
    final db = await database;
    await db.delete(
      'history',
      where: 'trackId = ?',
      whereArgs: [trackId],
    );
  }

  // --- Bulk wipe ---

  /// Empties every library table in a single transaction. Powers the
  /// "Clear all data" Settings action. Schema is preserved — only row
  /// content is removed — so the next launch reuses the same SQLite
  /// file without an upgrade dance. The on-disk audio / artwork files
  /// are deleted separately by [LibraryService.clearAllData] since
  /// they live outside the database.
  ///
  /// Foreign-key cascade from `playlists` would handle
  /// `playlist_tracks` automatically, but we delete every table
  /// explicitly to be obvious about intent and to keep this method
  /// safe under any future schema rework.
  Future<void> wipeAllData() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('history');
      await txn.delete('playlist_tracks');
      await txn.delete('playlists');
      await txn.delete('tracks');
    });
  }

  /// Closes the DB (e.g. for tests).
  Future<void> close() async {
    final d = _db;
    _db = null;
    if (d != null && d.isOpen) {
      await d.close();
    }
  }
}
