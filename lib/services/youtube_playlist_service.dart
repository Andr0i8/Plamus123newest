import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException;

import 'package:http/http.dart' as http;

import 'youtube_search_service.dart' show decodeYoutubeText, parseYoutubeInt;

/// One track inside a fetched playlist.
///
/// Mirrors the JSON shape returned by `GET /playlist?id=…`:
/// ```json
/// { "id", "title", "channel", "thumbnail", "url", "duration_seconds" }
/// ```
class YoutubePlaylistTrack {
  /// Creates a playlist track.
  const YoutubePlaylistTrack({
    required this.id,
    required this.title,
    required this.channel,
    required this.thumbnail,
    required this.url,
    required this.durationSeconds,
  });

  /// YouTube video id (e.g. `dQw4w9WgXcQ`).
  final String id;

  /// Title with HTML entities already decoded.
  final String title;

  /// Channel / uploader.
  final String channel;

  /// Direct URL to the YouTube thumbnail.
  final String thumbnail;

  /// Full `https://www.youtube.com/watch?v=…` URL — feeds straight into
  /// the existing per-track download pipeline (yt-dlp on desktop,
  /// AudioDownloadService on mobile).
  final String url;

  /// Length in seconds. `0` when unknown — the UI hides the duration
  /// label rather than showing "0:00".
  final int durationSeconds;

  /// Builds a track from the `tracks[]` items in a playlist response.
  factory YoutubePlaylistTrack.fromJson(Map<String, dynamic> json) {
    return YoutubePlaylistTrack(
      id: (json['id'] ?? '').toString(),
      title: decodeYoutubeText((json['title'] ?? '').toString()),
      channel: decodeYoutubeText((json['channel'] ?? '').toString()),
      thumbnail: (json['thumbnail'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      durationSeconds: parseYoutubeInt(json['duration_seconds']),
    );
  }
}

/// Full playlist payload returned by `GET /playlist?id=…`.
class YoutubePlaylistInfo {
  /// Creates a playlist info bundle.
  const YoutubePlaylistInfo({
    required this.id,
    required this.title,
    required this.channel,
    required this.thumbnail,
    required this.url,
    required this.trackCount,
    required this.totalDurationSeconds,
    required this.tracks,
  });

  /// YouTube playlist id.
  final String id;

  /// Playlist title.
  final String title;

  /// Owning channel.
  final String channel;

  /// Thumbnail URL.
  final String thumbnail;

  /// Public playlist URL.
  final String url;

  /// Server-reported track count. May differ from `tracks.length` when
  /// the playlist contains private / deleted entries that the YouTube
  /// API skips when listing items.
  final int trackCount;

  /// Sum of every track's `duration_seconds`. `0` when unknown.
  final int totalDurationSeconds;

  /// Ordered tracks from the playlist, suitable for iterating to download.
  final List<YoutubePlaylistTrack> tracks;

  /// Builds a playlist info from the top-level response object.
  factory YoutubePlaylistInfo.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['tracks'];
    final tracks = (rawTracks is List)
        ? rawTracks
            .whereType<Map<String, dynamic>>()
            .map(YoutubePlaylistTrack.fromJson)
            .where((t) => t.id.isNotEmpty && t.url.isNotEmpty)
            .toList(growable: false)
        : const <YoutubePlaylistTrack>[];
    return YoutubePlaylistInfo(
      id: (json['id'] ?? '').toString(),
      title: decodeYoutubeText((json['title'] ?? '').toString()),
      channel: decodeYoutubeText((json['channel'] ?? '').toString()),
      thumbnail: (json['thumbnail'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      trackCount: parseYoutubeInt(json['track_count']),
      totalDurationSeconds: parseYoutubeInt(json['total_duration_seconds']),
      tracks: tracks,
    );
  }
}

/// Thin client for the Plamus Railway playlist endpoint.
///
/// `GET https://web-production-1bab4.up.railway.app/playlist?id=<id>`
/// (or `?url=<full URL>`) returns the full playlist payload — id,
/// title, total duration, and all tracks with per-video durations.
///
/// Each returned [YoutubePlaylistTrack.url] is then fed back through the
/// existing download pipeline one at a time so the per-platform behavior
/// is preserved unchanged:
///   * Android — server-backed AudioDownloadService.
///   * Linux/Windows desktop — bundled yt-dlp via DownloadService.
class YoutubePlaylistService {
  YoutubePlaylistService._();

  /// Production server. Same instance the search and download services
  /// use; hard-coded to match `YoutubeSearchService._serverUrl`.
  static const String _serverUrl =
      'https://web-production-1bab4.up.railway.app';

  /// Long-ish timeout: the server may make several YouTube API roundtrips
  /// to enumerate a 200-track playlist with durations.
  static const Duration _timeout = Duration(seconds: 30);

  /// Fetches a playlist by its YouTube playlist id.
  ///
  /// Throws on network / server errors; callers (the playlist preview
  /// screen) catch the exception and surface "Could not load playlist".
  static Future<YoutubePlaylistInfo> fetchById(String playlistId) {
    return _fetch({'id': playlistId.trim()});
  }

  /// Fetches a playlist by its full YouTube URL.
  ///
  /// The server itself extracts the `list=` query parameter.
  static Future<YoutubePlaylistInfo> fetchByUrl(String playlistUrl) {
    return _fetch({'url': playlistUrl.trim()});
  }

  static Future<YoutubePlaylistInfo> _fetch(Map<String, String> query) async {
    if (query.values.every((v) => v.isEmpty)) {
      throw ArgumentError('Playlist id or URL must not be empty');
    }
    final uri = Uri.parse('$_serverUrl/playlist').replace(
      queryParameters: query,
    );

    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Playlist server returned ${response.statusCode}',
        uri: uri,
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      throw StateError('Playlist server returned invalid JSON: ${e.message}');
    }

    if (decoded is! Map<String, dynamic>) {
      throw StateError('Playlist response is not a JSON object');
    }
    if (decoded['error'] is String) {
      throw StateError('Playlist server error: ${decoded['error']}');
    }

    return YoutubePlaylistInfo.fromJson(decoded);
  }
}
