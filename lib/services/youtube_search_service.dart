import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// One row in a search response from the Plamus extraction server.
class YoutubeSearchResult {
  /// Creates an immutable search result.
  const YoutubeSearchResult({
    required this.id,
    required this.title,
    required this.channel,
    required this.thumbnail,
    required this.url,
  });

  /// YouTube video id (e.g. `dQw4w9WgXcQ`). Useful as a stable key.
  final String id;

  /// Human-readable title with HTML entities already decoded.
  final String title;

  /// Channel / uploader name with HTML entities already decoded.
  final String channel;

  /// Direct URL to the YouTube thumbnail (typically `mqdefault.jpg`).
  final String thumbnail;

  /// Full `https://www.youtube.com/watch?v=…` URL — feeds straight into the
  /// existing yt-dlp download pipeline.
  final String url;

  /// Builds a result from a single JSON object.
  factory YoutubeSearchResult.fromJson(Map<String, dynamic> json) {
    return YoutubeSearchResult(
      id: (json['id'] ?? '').toString(),
      title: _decodeHtmlEntities((json['title'] ?? '').toString()),
      channel: _decodeHtmlEntities((json['channel'] ?? '').toString()),
      thumbnail: (json['thumbnail'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
    );
  }
}

/// Thin client for the Plamus Railway search endpoint.
///
/// `GET https://web-production-1bab4.up.railway.app/search?q=<query>` →
/// ```json
/// { "results": [{ "id", "title", "channel", "thumbnail", "url" }, …] }
/// ```
///
/// Same Railway instance that handles `/download` for mobile. Search support
/// is currently surfaced on Linux desktop only — see
/// `_ImportPanelState._supportsSearch` in `import_panel.dart`.
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
// HTML entity decoding
// ---------------------------------------------------------------------------

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


