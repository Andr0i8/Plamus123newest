import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'youtube_api.dart';

/// Whether a [YoutubeSearchResult] points at a single video or a playlist
/// of videos. Drives both the tile UI (duration vs. track count) and the
/// tap behavior (direct download vs. open the preview screen).
enum YoutubeSearchKind { video, playlist }

/// One row in a YouTube search response.
///
/// Two flavors:
///   * `kind: video` — single video with [durationSeconds]. Tapping it
///     downloads via the existing per-track pipeline.
///   * `kind: playlist` — playlist with [trackCount]. Tapping opens a
///     preview screen that lists the playlist's tracks (fetched lazily
///     by [YoutubePlaylistService]) and offers "Download all".
///
/// The shape mirrors the historical Plamus server response so existing
/// UI code in the import panel and the playlist preview screen keeps
/// working unchanged.
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

  /// Direct URL to the YouTube thumbnail (typically `mqdefault.jpg` or
  /// the highest-resolution variant the API surfaced).
  final String thumbnail;

  /// Full URL — `https://www.youtube.com/watch?v=…` for videos,
  /// `https://www.youtube.com/playlist?list=…` for playlists.
  final String url;

  /// Length of the video in seconds. `0` when unknown (live stream,
  /// region-locked) or when [kind] is [YoutubeSearchKind.playlist].
  final int durationSeconds;

  /// Number of videos in the playlist. `0` when unknown or when [kind]
  /// is [YoutubeSearchKind.video].
  final int trackCount;

  /// Convenience accessors so call sites read nicely.
  bool get isVideo => kind == YoutubeSearchKind.video;
  bool get isPlaylist => kind == YoutubeSearchKind.playlist;
}

/// Pure-Dart YouTube search backed by the Data API v3.
///
/// `search.list` returns mixed video + playlist hits but does NOT carry
/// per-item durations or playlist track counts; we batch-fetch those
/// via `videos.list` (durations) and `playlists.list` (item counts) so
/// the UI can render the same `<title> · <duration | N tracks>` rows
/// the Plamus design has always shown.
///
/// Same code runs on every platform — Linux, Windows, Android. The
/// search request itself is independent of the per-platform download
/// pipeline (yt-dlp on desktop, Cobalt on Android).
class YoutubeSearchService {
  YoutubeSearchService._();

  /// Hard cap so a slow API call cannot freeze the search field forever.
  static const Duration _timeout = Duration(seconds: 15);

  /// Number of search hits per query. The Data API caps this at 50, but
  /// the UI only paints the first 25-ish before the user re-types, so
  /// 25 is a reasonable balance between recall and quota cost.
  static const int _maxResults = 25;

  /// Searches YouTube via the Data API and returns parsed results.
  ///
  /// Returns an empty list when [query] is blank — callers should treat
  /// that as "no search performed" rather than "no matches".
  ///
  /// Throws on network / quota / API errors so the caller can surface a
  /// "Search unavailable" message.
  static Future<List<YoutubeSearchResult>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    // Step 1: hit search.list for the mixed video + playlist hits.
    final searchResponse = await YoutubeApi.get(
      'search',
      {
        'part': 'snippet',
        'q': trimmed,
        'type': 'video,playlist',
        'maxResults': '$_maxResults',
        'safeSearch': 'none',
      },
      timeout: _timeout,
    );

    final items = searchResponse['items'];
    if (items is! List || items.isEmpty) {
      return const [];
    }

    // Step 2: walk the search hits, keep ordering, and remember which
    // ids we'll need to enrich with durations / track counts.
    final ordered = <_RawHit>[];
    final videoIds = <String>[];
    final playlistIds = <String>[];

    for (final raw in items) {
      if (raw is! Map<String, dynamic>) continue;
      final hit = _RawHit.tryParse(raw);
      if (hit == null) continue;
      ordered.add(hit);
      if (hit.kind == YoutubeSearchKind.video) {
        videoIds.add(hit.id);
      } else {
        playlistIds.add(hit.id);
      }
    }

    if (ordered.isEmpty) return const [];

    // Step 3: parallel batch fetches for the metadata the search call
    // didn't include. Each request is independent; running them in
    // parallel cuts latency roughly in half compared to sequential.
    final results = await Future.wait([
      _fetchVideoDurations(videoIds),
      _fetchPlaylistCounts(playlistIds),
    ]);
    final durations = results[0];
    final counts = results[1];

    // Step 4: rebuild in original search order with the enriched data.
    return ordered
        .map(
          (hit) => YoutubeSearchResult(
            kind: hit.kind,
            id: hit.id,
            title: hit.title,
            channel: hit.channel,
            thumbnail: hit.thumbnail,
            url: hit.url,
            durationSeconds: hit.kind == YoutubeSearchKind.video
                ? (durations[hit.id] ?? 0)
                : 0,
            trackCount: hit.kind == YoutubeSearchKind.playlist
                ? (counts[hit.id] ?? 0)
                : 0,
          ),
        )
        .toList(growable: false);
  }

  /// Batched `videos.list?part=contentDetails&id=…` request. Returns a
  /// map of video id → duration in seconds. Empty when [ids] is empty.
  static Future<Map<String, int>> _fetchVideoDurations(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final result = <String, int>{};
    for (final chunk in chunkIds(ids)) {
      try {
        final response = await YoutubeApi.get(
          'videos',
          {
            'part': 'contentDetails',
            'id': chunk.join(','),
            'maxResults': '${chunk.length}',
          },
          timeout: _timeout,
        );
        final items = response['items'];
        if (items is! List) continue;
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final id = raw['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final details = raw['contentDetails'];
          final iso = (details is Map ? details['duration'] : null)?.toString();
          if (iso == null) continue;
          result[id] = parseIso8601DurationSeconds(iso);
        }
      } catch (e) {
        // Search results are still useful without per-row durations —
        // log and skip rather than failing the whole search.
        debugPrint('YoutubeSearchService: video duration batch failed: $e');
      }
    }
    return result;
  }

  /// Batched `playlists.list?part=contentDetails&id=…` request. Returns
  /// a map of playlist id → item count. Empty when [ids] is empty.
  static Future<Map<String, int>> _fetchPlaylistCounts(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final result = <String, int>{};
    for (final chunk in chunkIds(ids)) {
      try {
        final response = await YoutubeApi.get(
          'playlists',
          {
            'part': 'contentDetails',
            'id': chunk.join(','),
            'maxResults': '${chunk.length}',
          },
          timeout: _timeout,
        );
        final items = response['items'];
        if (items is! List) continue;
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final id = raw['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final details = raw['contentDetails'];
          final count = parseYoutubeInt(
            details is Map ? details['itemCount'] : null,
          );
          result[id] = count;
        }
      } catch (e) {
        debugPrint('YoutubeSearchService: playlist count batch failed: $e');
      }
    }
    return result;
  }
}

/// Internal struct: the parts of a `search.list` hit we can extract
/// without any follow-up calls.
class _RawHit {
  const _RawHit({
    required this.kind,
    required this.id,
    required this.title,
    required this.channel,
    required this.thumbnail,
    required this.url,
  });

  final YoutubeSearchKind kind;
  final String id;
  final String title;
  final String channel;
  final String thumbnail;
  final String url;

  /// Builds a [_RawHit] from a single `items[]` entry, returning `null`
  /// for shapes the renderer can't consume (channel hits, missing ids).
  static _RawHit? tryParse(Map<String, dynamic> raw) {
    final idObj = raw['id'];
    if (idObj is! Map) return null;
    final kindStr = idObj['kind']?.toString() ?? '';

    final YoutubeSearchKind kind;
    final String id;
    final String url;

    if (kindStr == 'youtube#video') {
      kind = YoutubeSearchKind.video;
      id = idObj['videoId']?.toString() ?? '';
      url = id.isEmpty ? '' : 'https://www.youtube.com/watch?v=$id';
    } else if (kindStr == 'youtube#playlist') {
      kind = YoutubeSearchKind.playlist;
      id = idObj['playlistId']?.toString() ?? '';
      url = id.isEmpty ? '' : 'https://www.youtube.com/playlist?list=$id';
    } else {
      // Channel hits and other kinds are ignored — we only render
      // playable content in the search UI.
      return null;
    }

    if (id.isEmpty) return null;

    final snippet = raw['snippet'];
    if (snippet is! Map) return null;

    return _RawHit(
      kind: kind,
      id: id,
      title: decodeYoutubeText(snippet['title']?.toString() ?? ''),
      channel: decodeYoutubeText(snippet['channelTitle']?.toString() ?? ''),
      thumbnail: pickThumbnailUrl(snippet['thumbnails']),
      url: url,
    );
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
/// The Data API v3 mostly returns clean UTF-8 strings, but some titles
/// (particularly older uploads) still come through with `&amp;` /
/// `&#39;` etc. Decoding here is a no-op for clean strings and keeps
/// the UI safe from raw entity bleed-through.
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
