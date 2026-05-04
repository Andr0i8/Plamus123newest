import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// Whether a [YoutubeSearchResult] points at a single video or a playlist
/// of videos. Drives both the tile UI (duration vs. track count) and the
/// tap behavior (direct download vs. open the preview screen).
enum YoutubeSearchKind { video, playlist }

/// One row in a search response from the Plamus extraction server.
///
/// The server can return either of:
///   * `type: "video"` — single video with `duration_seconds`. Tapping it
///     downloads via the existing per-track pipeline.
///   * `type: "playlist"` — playlist with `track_count`. Tapping opens a
///     preview screen that lists the playlist's tracks (fetched lazily
///     from the `/playlist` endpoint) and offers "Download all".
///
/// All response fields are parsed defensively — missing or unexpected
/// values default to a benign "video with unknown duration", so an older
/// server build (pre-playlist support) still produces working video rows.
class YoutubeSearchResult {
  /// Creates an immutable search result.
  const YoutubeSearchResult({
    required this.kind,
    required this.id,
    required this.title,
    required this.channel,
    required this.thumbnail,
    required this.url,
    this.durationSeconds = 0,
    this.trackCount = 0,
  });

  /// `video` or `playlist`.
  final YoutubeSearchKind kind;

  /// YouTube id — video id for [kind] = video, playlist id for playlist.
  final String id;

  /// Human-readable title with HTML entities already decoded.
  final String title;

  /// Channel / uploader name with HTML entities already decoded.
  final String channel;

  /// Direct URL to the YouTube thumbnail (typically `mqdefault.jpg`).
  final String thumbnail;

  /// Full URL — `https://www.youtube.com/watch?v=…` for videos,
  /// `https://www.youtube.com/playlist?list=…` for playlists. The video
  /// form feeds straight into the existing yt-dlp / extractor download
  /// pipeline; the playlist form is forwarded to the `/playlist` endpoint
  /// to enumerate its tracks.
  final String url;

  /// Length of the video in seconds. `0` when unknown (older server) or
  /// when [kind] is [YoutubeSearchKind.playlist].
  final int durationSeconds;

  /// Number of videos in the playlist. `0` when unknown or when [kind] is
  /// [YoutubeSearchKind.video].
  final int trackCount;

  /// Convenience accessors so call sites read nicely.
  bool get isVideo => kind == YoutubeSearchKind.video;
  bool get isPlaylist => kind == YoutubeSearchKind.playlist;

  /// Builds a result from a single JSON object.
  ///
  /// Defaults [kind] to [YoutubeSearchKind.video] when `type` is missing
  /// so we stay compatible with the pre-playlist server build.
  factory YoutubeSearchResult.fromJson(Map<String, dynamic> json) {
    final rawType = (json['type'] ?? '').toString().toLowerCase();
    final kind = rawType == 'playlist'
        ? YoutubeSearchKind.playlist
        : YoutubeSearchKind.video;
    return YoutubeSearchResult(
      kind: kind,
      id: (json['id'] ?? '').toString(),
      title: _decodeHtmlEntities((json['title'] ?? '').toString()),
      channel: _decodeHtmlEntities((json['channel'] ?? '').toString()),
      thumbnail: (json['thumbnail'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      durationSeconds: _readInt(json['duration_seconds']),
      trackCount: _readInt(json['track_count']),
    );
  }
}

/// Thin client for the Plamus Railway search endpoint.
///
/// `GET https://web-production-1bab4.up.railway.app/search?q=<query>` →
/// ```json
/// { "results": [
///     { "type": "video",    "id", "title", "channel", "thumbnail",
///       "url", "duration_seconds" },
///     { "type": "playlist", "id", "title", "channel", "thumbnail",
///       "url", "track_count" },
///     …
///   ] }
/// ```
///
/// Same Railway instance that handles `/download` for mobile and
/// `/playlist` for full playlist listings (see [YoutubePlaylistService]).
class YoutubeSearchService {
  YoutubeSearchService._();

  /// Production server. Hard-coded to match `YoutubeDownloadService`.
  static const String _serverUrl =
      'https://web-production-1bab4.up.railway.app';

  /// Cap so a slow server can never freeze the search field forever.
  static const Duration _timeout = Duration(seconds: 15);

  /// Searches YouTube via the Plamus server and returns parsed results.
  ///
  /// Returns an empty list when [query] is blank — callers should treat that
  /// as "no search performed" rather than "no matches".
  ///
  /// Throws on network / server errors so the caller can surface a
  /// "Search unavailable" message.
  static Future<List<YoutubeSearchResult>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final uri = Uri.parse('$_serverUrl/search').replace(
      queryParameters: {'q': trimmed},
    );

    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Search server returned ${response.statusCode}',
        uri: uri,
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      throw StateError('Search server returned invalid JSON: ${e.message}');
    }

    if (decoded is! Map<String, dynamic>) {
      throw StateError('Search response is not a JSON object');
    }
    final raw = decoded['results'];
    if (raw is! List) {
      // Server returned something like `{"error": "..."}` — treat as empty.
      debugPrint('YoutubeSearchService: missing "results" array in $decoded');
      return const [];
    }

    return raw
        .whereType<Map<String, dynamic>>()
        .map(YoutubeSearchResult.fromJson)
        .where((r) => r.id.isNotEmpty && r.url.isNotEmpty)
        .toList(growable: false);
  }
}

// ---------------------------------------------------------------------------
// Internal helpers (shared with YoutubePlaylistService)
// ---------------------------------------------------------------------------

/// Reads an int from a JSON value that may be int, double, string, or null.
/// Returns 0 for anything unparseable so the UI can simply hide the field.
int _readInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is double) return raw.toInt();
  if (raw is String) {
    final parsed = int.tryParse(raw.trim());
    if (parsed != null) return parsed;
  }
  return 0;
}

const Map<String, String> _namedHtmlEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00A0',
  'hellip': '\u2026',
  'mdash': '\u2014',
  'ndash': '\u2013',
  'lsquo': '\u2018',
  'rsquo': '\u2019',
  'ldquo': '\u201C',
  'rdquo': '\u201D',
};

/// Decodes the most common HTML entities found in YouTube titles.
///
/// Handles named entities (`&amp;`, `&quot;`, …) and numeric ones
/// (`&#39;`, `&#x2019;`). Leaves unknown entities untouched rather than
/// throwing — search is non-critical and we'd rather show a slightly ugly
/// title than no title at all.
String _decodeHtmlEntities(String input) {
  if (!input.contains('&')) return input;
  return input.replaceAllMapped(
    RegExp(r'&(#x?[0-9A-Fa-f]+|[a-zA-Z][a-zA-Z0-9]*);'),
    (match) {
      final raw = match.group(1)!;
      if (raw.startsWith('#x') || raw.startsWith('#X')) {
        final code = int.tryParse(raw.substring(2), radix: 16);
        if (code != null) return String.fromCharCode(code);
      } else if (raw.startsWith('#')) {
        final code = int.tryParse(raw.substring(1));
        if (code != null) return String.fromCharCode(code);
      } else {
        final replacement = _namedHtmlEntities[raw];
        if (replacement != null) return replacement;
      }
      return match.group(0)!; // unknown — preserve the raw entity
    },
  );
}

/// Decoder shared with [YoutubePlaylistService] so playlist track titles
/// also have HTML entities resolved.
String decodeYoutubeText(String input) => _decodeHtmlEntities(input);

/// Public wrapper around the integer parser used by both services.
int parseYoutubeInt(Object? raw) => _readInt(raw);
