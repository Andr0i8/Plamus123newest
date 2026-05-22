import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Downloads cover artwork (currently: YouTube video thumbnails) and saves
/// it next to the audio file so the rest of the app can render it from
/// disk without re-fetching.
///
/// Strategy:
///   1. Pull the video id out of [sourceUrl] (or accept a bare 11-char id).
///   2. Try YouTube's standard thumbnail URLs in descending quality:
///        maxresdefault → sddefault → hqdefault → mqdefault → default.
///      The highest-resolution variant only exists for some videos
///      (livestreams / very short clips lack it), so we fall through on
///      404 / 0-byte responses until one succeeds.
///   3. Save the bytes as `<audio basename>.jpg` alongside the audio file.
///      Re-uses the same `_resolveUniquePath` convention as the audio
///      downloaders to avoid stomping a sibling file.
///
/// Failures are swallowed and surfaced as `null` — artwork is purely
/// decorative, so a missing thumbnail must never block the audio import.
class ArtworkService {
  ArtworkService._();

  /// Maximum number of bytes we'll accept for a single artwork file. Real
  /// thumbnails are tens to a few hundred KB; cap conservatively to fail
  /// fast on a misbehaving CDN response.
  static const int _maxBytes = 8 * 1024 * 1024;

  /// Per-attempt HTTP timeout. The whole pipeline is bounded so a slow
  /// download never holds up the audio import or the Library refresh.
  static const Duration _timeout = Duration(seconds: 20);

  /// Ordered list of candidate filename qualities served by YouTube's
  /// `i.ytimg.com` CDN. Highest quality first.
  static const List<String> _candidateQualities = [
    'maxresdefault.jpg',
    'sddefault.jpg',
    'hqdefault.jpg',
    'mqdefault.jpg',
    'default.jpg',
  ];

  /// Attempts to download artwork for the YouTube [sourceUrl] and save it
  /// next to [audioFilePath]. Returns the absolute path on success, or
  /// `null` when no artwork could be obtained (non-YouTube URL, network
  /// error, every candidate returned 404, etc.).
  ///
  /// [explicitThumbnailUrl] may be passed by callers that already know the
  /// best image URL (e.g. the server-provided `X-Track-Thumbnail` header
  /// or a search-result thumbnail). When non-null it is tried first, and
  /// the candidate-quality fallback runs only if it fails.
  static Future<String?> downloadArtworkForYoutube({
    required String sourceUrl,
    required String audioFilePath,
    String? explicitThumbnailUrl,
  }) async {
    final urls = <String>[];

    final explicit = explicitThumbnailUrl?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      urls.add(explicit);
    }

    final videoId = extractYoutubeVideoId(sourceUrl);
    if (videoId != null) {
      for (final quality in _candidateQualities) {
        urls.add('https://i.ytimg.com/vi/$videoId/$quality');
      }
    }

    if (urls.isEmpty) {
      return null;
    }

    final outDir = Directory(p.dirname(audioFilePath));
    if (!await outDir.exists()) {
      try {
        await outDir.create(recursive: true);
      } catch (e) {
        debugPrint('ArtworkService: cannot create $outDir: $e');
        return null;
      }
    }

    final destPath = await _resolveArtworkPath(audioFilePath);

    final client = http.Client();
    try {
      for (final url in urls) {
        final saved = await _tryFetch(client, url, destPath);
        if (saved != null) return saved;
      }
    } finally {
      client.close();
    }
    return null;
  }

  /// Saves an arbitrary thumbnail [url] alongside [audioFilePath] without
  /// any YouTube-specific fallbacks. Used for explicit image URLs (e.g.
  /// search-result thumbnails, server-provided headers) where the caller
  /// has already picked the resolution they want.
  static Future<String?> downloadArtworkFromUrl({
    required String url,
    required String audioFilePath,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    final destPath = await _resolveArtworkPath(audioFilePath);
    final client = http.Client();
    try {
      return await _tryFetch(client, trimmed, destPath);
    } finally {
      client.close();
    }
  }

  /// Extracts the YouTube video id from [url] if it points at a watch /
  /// short / embed URL or is itself a bare 11-char video id. Returns
  /// `null` for any other input (including playlist URLs without a `v=`).
  static String? extractYoutubeVideoId(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;

    // Bare 11-char video id (e.g. "dQw4w9WgXcQ").
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(trimmed)) {
      return trimmed;
    }

    Uri? uri;
    try {
      uri = Uri.parse(trimmed);
    } catch (_) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return null;

    // youtu.be/<id>
    if (host == 'youtu.be' || host.endsWith('.youtu.be')) {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isNotEmpty) return _sanitizeId(segments.first);
      return null;
    }

    final isYouTube = host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtube-nocookie.com' ||
        host.endsWith('.youtube-nocookie.com');
    if (!isYouTube) return null;

    // Standard watch URL: /watch?v=<id>
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) return _sanitizeId(v);

    // /embed/<id>, /shorts/<id>, /v/<id>
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length >= 2) {
      const idCarrierFolders = {'embed', 'shorts', 'v', 'live'};
      if (idCarrierFolders.contains(segments.first.toLowerCase())) {
        return _sanitizeId(segments[1]);
      }
    }
    return null;
  }

  /// Resolves the on-disk artwork path next to [audioFilePath].
  ///
  /// Always returns `<audio basename>.jpg`. We deliberately overwrite
  /// existing artwork so re-downloading the same track replaces a stale
  /// thumbnail with a fresh one rather than accumulating `_1`, `_2`
  /// siblings. Callers that move audio in/out of the library are
  /// responsible for cleaning up orphaned artwork files.
  static Future<String> _resolveArtworkPath(String audioFilePath) async {
    final dir = p.dirname(audioFilePath);
    final base = p.basenameWithoutExtension(audioFilePath);
    return p.join(dir, '$base.jpg');
  }

  /// Issues a single GET to [url] and writes the body to [destPath] when
  /// it looks like a real image. Returns the saved path on success, or
  /// `null` for any error (including 404 and 0-byte responses).
  static Future<String?> _tryFetch(
    http.Client client,
    String url,
    String destPath,
  ) async {
    try {
      final response = await client.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode != 200) {
        debugPrint(
            'ArtworkService: $url returned ${response.statusCode}, skipping');
        return null;
      }
      final bytes = response.bodyBytes;
      // YouTube returns a tiny placeholder image (~1KB / 120x90 grey
      // square) for missing maxresdefault rather than a 404 — guard
      // against accepting that as the "winning" candidate.
      if (bytes.length < 1024) {
        debugPrint(
            'ArtworkService: $url body too small (${bytes.length}B), skipping');
        return null;
      }
      if (bytes.length > _maxBytes) {
        debugPrint(
            'ArtworkService: $url body too large (${bytes.length}B), skipping');
        return null;
      }
      final file = File(destPath);
      await file.writeAsBytes(bytes, flush: true);
      debugPrint(
          'ArtworkService: saved $destPath (${bytes.length}B) from $url');
      return destPath;
    } catch (e) {
      debugPrint('ArtworkService: failed $url: $e');
      return null;
    }
  }

  /// Defensive trim for ids parsed out of a URL: drop any trailing query
  /// fragments that slipped through (e.g. a stray `&t=10s` on a segment),
  /// and require the canonical 11-char alphabet.
  static String? _sanitizeId(String raw) {
    final trimmed = raw.split(RegExp(r'[?&#]')).first;
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(trimmed)) {
      return trimmed;
    }
    // Allow longer ids to be returned uncorrected — YouTube has stable
    // 11-char ids today, but if the format ever expands we'd rather try
    // the URL than silently drop it.
    if (RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(trimmed)) {
      return trimmed;
    }
    return null;
  }
}
