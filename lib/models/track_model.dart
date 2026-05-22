/// Domain model for a single audio [Track] row in SQLite.
///
/// Maps to the `tracks` table. [durationMs] is stored in milliseconds for
/// precision; [isLiked] mirrors the smart "Liked Songs" list.
class TrackModel {
  /// Creates a track with optional [id] (null before insert).
  const TrackModel({
    this.id,
    required this.title,
    required this.artist,
    required this.filePath,
    this.sourceUrl,
    this.artworkPath,
    required this.durationMs,
    this.isLiked = false,
    this.inLibrary = true,
    required this.dateAdded,
  });

  /// SQLite primary key; null when not yet persisted.
  final int? id;

  /// Display title; user-editable and may differ from file name.
  final String title;

  /// Artist or "Unknown" when missing.
  final String artist;

  /// UI label for [artist]: empty or generic "Unknown" → "Various Artists".
  String get displayArtistLabel {
    final a = artist.trim();
    if (a.isEmpty || a.toLowerCase() == 'unknown') {
      return 'Various Artists';
    }
    return a;
  }

  /// Absolute path to the audio file on disk (library or user folder).
  final String filePath;

  /// Original YouTube URL used to download this track, when available.
  ///
  /// Local imports and non-YouTube direct downloads leave this null, so the
  /// UI can hide/disable share actions for tracks that have no online source.
  final String? sourceUrl;

  /// Trimmed source URL suitable for clipboard sharing, or null when absent.
  String? get shareableSourceUrl {
    final value = sourceUrl?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Absolute path to a locally-saved cover image (typically a YouTube
  /// thumbnail downloaded next to the audio file). `null` for tracks that
  /// were imported as local files or downloaded before artwork support
  /// landed — the UI falls back to the generic placeholder for those.
  final String? artworkPath;

  /// Duration in milliseconds (0 if unknown).
  final int durationMs;

  /// When true, track appears in the Liked Songs smart list.
  final bool isLiked;

  /// When false, this track was imported directly into a specific playlist
  /// and should NOT appear in the main library list (it still lives in
  /// the `tracks` table because playlists reference it via `playlist_tracks`).
  final bool inLibrary;

  /// When the track was added to the library (ISO-8601 string).
  final String dateAdded;

  /// Builds a [TrackModel] from a SQLite row map.
  factory TrackModel.fromMap(Map<String, Object?> map) {
    return TrackModel(
      id: map['id'] as int?,
      title: map['title'] as String? ?? 'Untitled',
      artist: map['artist'] as String? ?? 'Unknown',
      filePath: map['filePath'] as String? ?? '',
      sourceUrl: map['sourceUrl'] as String?,
      artworkPath: map['artworkPath'] as String?,
      durationMs: (map['durationMs'] as int?) ?? 0,
      isLiked: ((map['isLiked'] as int?) ?? 0) == 1,
      // Default to true so older rows inserted before the v2 migration
      // (or rows from joins that don't select the column) still surface
      // in the library.
      inLibrary: ((map['inLibrary'] as int?) ?? 1) == 1,
      dateAdded: map['dateAdded'] as String? ?? '',
    );
  }

  /// Converts this model to a map for inserts/updates (excludes null [id] on insert).
  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'artist': artist,
      'filePath': filePath,
      'sourceUrl': sourceUrl,
      'artworkPath': artworkPath,
      'durationMs': durationMs,
      'isLiked': isLiked ? 1 : 0,
      'inLibrary': inLibrary ? 1 : 0,
      'dateAdded': dateAdded,
    };
  }

  /// Returns a copy with selective overrides.
  ///
  /// To explicitly clear [artworkPath] (e.g. after the file was deleted on
  /// disk), pass [clearArtwork] = true. [artworkPath] alone cannot
  /// represent "set to null" because Dart treats unspecified named
  /// parameters as null too — the boolean disambiguates "leave as-is" vs.
  /// "clear it". Same convention follows for [sourceUrl] / [clearSourceUrl]
  /// for symmetry.
  TrackModel copyWith({
    int? id,
    String? title,
    String? artist,
    String? filePath,
    String? sourceUrl,
    bool clearSourceUrl = false,
    String? artworkPath,
    bool clearArtwork = false,
    int? durationMs,
    bool? isLiked,
    bool? inLibrary,
    String? dateAdded,
  }) {
    return TrackModel(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      filePath: filePath ?? this.filePath,
      sourceUrl: clearSourceUrl ? null : (sourceUrl ?? this.sourceUrl),
      artworkPath: clearArtwork ? null : (artworkPath ?? this.artworkPath),
      durationMs: durationMs ?? this.durationMs,
      isLiked: isLiked ?? this.isLiked,
      inLibrary: inLibrary ?? this.inLibrary,
      dateAdded: dateAdded ?? this.dateAdded,
    );
  }
}
