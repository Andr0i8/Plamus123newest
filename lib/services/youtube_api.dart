import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// Shared low-level client for the YouTube Data API v3.
///
/// Plamus used to delegate every search / playlist lookup to a Python
/// Flask server that wrapped `yt-dlp`. The server is gone — Dart now
/// talks to the public YouTube Data API directly. The API is hard rate-
/// limited per key (10 000 units / day), so we keep three keys and
/// rotate to the next one as soon as the current key returns
/// `quotaExceeded` or `dailyLimitExceeded`.
///
/// The rotation is sticky: once a key works, [_currentKeyIndex] sticks
/// to it for every subsequent request in the session, so we don't burn
/// the daily quota of the lower-index keys faster than necessary.
///
/// Used by:
///   * [YoutubeSearchService] — `search.list` + batched `videos.list` /
///     `playlists.list` for durations and item counts.
///   * [YoutubePlaylistService] — `playlists.list`,
///     `playlistItems.list` (paginated), and batched `videos.list` for
///     per-track durations.
///   * [CobaltDownloadService] (deprecated) — historically used
///     `videos.list` to enrich the downloaded file with the real title
///     / channel name. The active Android path
///     ([YoutubeDownloadService]) gets that metadata directly from the
///     extraction server's `X-Track-*` response headers, so it doesn't
///     touch the Data API.
class YoutubeApi {
  YoutubeApi._();

  /// Hard-coded keys with automatic rotation. Order is the rotation
  /// order on cold start — the current selection is preserved across
  /// requests in the same process via [_currentKeyIndex].
  static const List<String> _apiKeys = [
    'AIzaSyBddO94_haO-8ZTCWUQ8ATR3mN38_rz3HY',
    'AIzaSyAjgN1O-09ffAIj9MtFlKfeBHBkWGz133Q',
    'AIzaSyD93Er0K0NTGmO1B9mAxI5z98qLL3tLoFY',
  ];

  /// Index into [_apiKeys] used by the next request. Advances only when
  /// the current key returns a quota-exhausted error.
  static int _currentKeyIndex = 0;

  /// Base endpoint for every Data API v3 method.
  static const String _baseUrl = 'https://www.googleapis.com/youtube/v3';

  /// Default per-request timeout. Search / playlist metadata responds in
  /// ~200ms; we allow plenty of headroom for slow networks.
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// Performs a `GET` against the Data API at [path] with the given
  /// [queryParameters], rotating through [_apiKeys] on quota errors.
  ///
  /// [path] should NOT start with a leading slash (e.g. `'search'`,
  /// `'videos'`). The `key` parameter is added automatically.
  ///
  /// Throws [StateError] if every key is exhausted, or if the API
  /// returns a non-quota error.
  static Future<Map<String, dynamic>> get(
    String path,
    Map<String, String> queryParameters, {
    Duration timeout = defaultTimeout,
  }) async {
    Object? lastError;

    // Try every key starting from the current one. Cycling is bounded
    // by the key count so an "all exhausted" condition surfaces as a
    // clear error rather than an infinite loop.
    for (var attempt = 0; attempt < _apiKeys.length; attempt++) {
      final keyIndex = (_currentKeyIndex + attempt) % _apiKeys.length;
      final key = _apiKeys[keyIndex];
      final uri = Uri.parse('$_baseUrl/$path').replace(
        queryParameters: {
          ...queryParameters,
          'key': key,
        },
      );

      final http.Response response;
      try {
        response = await http.get(uri).timeout(timeout);
      } on TimeoutException catch (e) {
        lastError = e;
        debugPrint('YoutubeApi: $path timed out on key #$keyIndex');
        continue;
      } catch (e) {
        // Network errors aren't quota-related, but they're transient
        // enough that retrying with another key is still reasonable.
        lastError = e;
        debugPrint('YoutubeApi: $path failed on key #$keyIndex: $e');
        continue;
      }

      final dynamic decoded;
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException catch (e) {
        throw StateError('YouTube API returned invalid JSON: ${e.message}');
      }
      if (decoded is! Map<String, dynamic>) {
        throw StateError('YouTube API returned non-object response');
      }

      // Success: lock the rotation onto the key that worked so the next
      // request doesn't burn the previously-exhausted keys' quota.
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _currentKeyIndex = keyIndex;
        return decoded;
      }

      // Non-2xx: distinguish a quota error (rotate) from any other
      // failure (surface immediately so callers see a useful message).
      if (_isQuotaError(decoded)) {
        lastError = StateError(
          'YouTube API key #$keyIndex exhausted (quota / daily limit).',
        );
        debugPrint('YoutubeApi: $path key #$keyIndex exhausted, rotating.');
        continue;
      }

      final error = decoded['error'];
      final message =
          (error is Map<String, dynamic> ? error['message'] : null)?.toString() ??
              decoded.toString();
      throw StateError(
        'YouTube API error ${response.statusCode} on $path: $message',
      );
    }

    throw StateError(
      'All YouTube API keys are exhausted. Last error: $lastError',
    );
  }

  /// Returns true when [body] contains a `quotaExceeded` or
  /// `dailyLimitExceeded` reason in the standard Data API error envelope:
  /// ```json
  /// { "error": { "errors": [ { "reason": "quotaExceeded", ... } ] } }
  /// ```
  static bool _isQuotaError(Map<String, dynamic> body) {
    final error = body['error'];
    if (error is! Map<String, dynamic>) return false;
    final errors = error['errors'];
    if (errors is! List) return false;
    for (final e in errors) {
      if (e is! Map<String, dynamic>) continue;
      final reason = e['reason']?.toString() ?? '';
      if (reason == 'quotaExceeded' || reason == 'dailyLimitExceeded') {
        return true;
      }
    }
    return false;
  }
}

/// Parses an ISO 8601 duration as returned by the Data API
/// (`videos.list` `contentDetails.duration`) into seconds.
///
/// Accepts the YouTube subset:
///   * `PT4M13S` → 253
///   * `PT1H2M3S` → 3723
///   * `PT45S`   → 45
///   * `P0D`     → 0 (live streams report this)
///
/// Returns 0 for any value the parser does not understand so the UI can
/// simply hide the duration label rather than blow up the search list.
int parseIso8601DurationSeconds(String input) {
  if (input.isEmpty) return 0;
  final match = RegExp(
    r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
  ).firstMatch(input);
  if (match == null) return 0;
  final days = int.tryParse(match.group(1) ?? '0') ?? 0;
  final hours = int.tryParse(match.group(2) ?? '0') ?? 0;
  final minutes = int.tryParse(match.group(3) ?? '0') ?? 0;
  final seconds = int.tryParse(match.group(4) ?? '0') ?? 0;
  return days * 86400 + hours * 3600 + minutes * 60 + seconds;
}

/// Picks the best thumbnail URL from a Data API `snippet.thumbnails`
/// object, in descending quality order.
///
/// The API's standard sizes are: `maxres` (1280×720), `standard`
/// (640×480), `high` (480×360), `medium` (320×180), `default` (120×90).
/// Not every video has a `maxres` thumbnail (livestreams / short clips
/// lack it), so we walk the size ladder and return the first hit.
String pickThumbnailUrl(Object? thumbnails) {
  if (thumbnails is! Map) return '';
  for (final size in const ['maxres', 'standard', 'high', 'medium', 'default']) {
    final entry = thumbnails[size];
    if (entry is Map) {
      final url = entry['url'];
      if (url is String && url.isNotEmpty) return url;
    }
  }
  return '';
}

/// Splits [ids] into chunks of at most [chunkSize] entries, suitable for
/// the Data API's batch `id=a,b,c` parameter (the v3 hard limit is 50).
Iterable<List<String>> chunkIds(List<String> ids, {int chunkSize = 50}) sync* {
  for (var i = 0; i < ids.length; i += chunkSize) {
    yield ids.sublist(i, (i + chunkSize).clamp(0, ids.length));
  }
}
