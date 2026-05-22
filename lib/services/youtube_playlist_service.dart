import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'youtube_api.dart';
import 'youtube_search_service.dart' show decodeYoutubeText, parseYoutubeInt;

/// One track inside a fetched playlist.
///
/// Mirrors the shape used by the Plamus UI before the search migration
/// (the JSON keys came from the old Python server). All fields except
/// [durationSeconds] come from the Data API's `playlistItems.list`
/// response; [durationSeconds] requires a follow-up batched
/// `videos.list` call so we can render `m:ss` in the preview list.
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

  /// Channel / uploader of the underlying video. Falls back to the
  /// playlist owner's channel name when the per-video field is missing.
  final String channel;

  /// Direct URL to the YouTube thumbnail.
  final String thumbnail;

  /// Full `https://www.youtube.com/watch?v=…` URL — feeds straight into
  /// the existing per-track download pipeline (yt-dlp on desktop,
  /// YoutubeDownloadService on Android).
  final String url;

  /// Length in seconds. `0` when unknown — the UI hides the duration
  /// label rather than showing "0:00".
  final int durationSeconds;
}

/// Full playlist payload returned by [YoutubePlaylistService.fetchById].
///
/// Same field set the Plamus UI has always rendered. The total duration
/// is computed client-side from the per-track durations rather than
/// fetched separately — the Data API does not expose a "playlist total
/// duration" endpoint, so we sum what we got from `videos.list`.
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

  /// Server-reported track count (`contentDetails.itemCount`). May
  /// differ from `tracks.length` when the playlist contains
  /// private / deleted entries the API skips when listing items.
  final int trackCount;

  /// Sum of every track's `durationSeconds`. `0` when unknown.
  final int totalDurationSeconds;

  /// Ordered tracks from the playlist, suitable for iterating to
  /// download.
  final List<YoutubePlaylistTrack> tracks;
}

/// Pure-Dart YouTube playlist fetcher backed by the Data API v3.
///
/// Replaces the old `/playlist` endpoint on the Plamus server. Three
/// API methods are involved:
///
///   1. `playlists.list` — playlist metadata (title, channel,
///      itemCount, thumbnail).
///   2. `playlistItems.list` — paginated track list (50 items / page,
///      driven by `nextPageToken`).
///   3. `videos.list` — batched per-track durations (50 ids / batch).
///
/// For a 200-track playlist this is roughly 1 + 4 + 4 = 9 API calls,
/// well within the per-key 10 000 unit/day budget.
class YoutubePlaylistService {
  YoutubePlaylistService._();

  /// Long-ish timeout: large playlists trigger several roundtrips and
  /// the per-call latency adds up.
  static const Duration _timeout = Duration(seconds: 30);

  /// Fetches a playlist by its YouTube playlist id.
  ///
  /// Throws on network / quota / API errors; callers (the playlist
  /// preview screen) catch the exception and surface "Could not load
  /// playlist".
  static Future<YoutubePlaylistInfo> fetchById(String playlistId) {
    final id = playlistId.trim();
    if (id.isEmpty) {
      throw ArgumentError('Playlist id must not be empty');
    }
    return _fetch(id);
  }

  /// Fetches a playlist by its full YouTube URL. Extracts the `list=…`
  /// query parameter and delegates to [fetchById].
  static Future<YoutubePlaylistInfo> fetchByUrl(String playlistUrl) {
    final id = _extractPlaylistId(playlistUrl);
    if (id == null) {
      throw ArgumentError(
        'Could not parse playlist id from URL: $playlistUrl',
      );
    }
    return fetchById(id);
  }

  static Future<YoutubePlaylistInfo> _fetch(String playlistId) async {
    // Step 1: playlist metadata. The API returns a list `items[]` even
    // for a single id — we take the first hit. Empty list means the
    // playlist is private / deleted / never existed.
    final metaResponse = await YoutubeApi.get(
      'playlists',
      {
        'part': 'snippet,contentDetails',
        'id': playlistId,
        'maxResults': '1',
      },
      timeout: _timeout,
    );

    final metaItems = metaResponse['items'];
    if (metaItems is! List || metaItems.isEmpty) {
      throw StateError(
        'Playlist not found or is not public: $playlistId',
      );
    }
    final meta = metaItems.first;
    if (meta is! Map<String, dynamic>) {
      throw StateError('Unexpected playlist metadata shape');
    }

    final snippet = meta['snippet'];
    final contentDetails = meta['contentDetails'];
    final title = snippet is Map
        ? decodeYoutubeText(snippet['title']?.toString() ?? '')
        : '';
    final channel = snippet is Map
        ? decodeYoutubeText(snippet['channelTitle']?.toString() ?? '')
        : '';
    final thumbnail = snippet is Map
        ? pickThumbnailUrl(snippet['thumbnails'])
        : '';
    final reportedCount = contentDetails is Map
        ? parseYoutubeInt(contentDetails['itemCount'])
        : 0;

    // Step 2: walk every page of playlistItems.list. Each track gives
    // us videoId + per-video metadata; durations need a follow-up batch.
    final tracks = await _fetchAllTracks(playlistId, channel);

    // Step 3: batch the video ids in groups of 50 and resolve durations
    // via videos.list?part=contentDetails. Tracks without a recovered
    // duration keep `0`, matching the historical UI fallback.
    final videoIds = tracks
        .map((t) => t.id)
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final durations = await _fetchVideoDurations(videoIds);

    final enrichedTracks = tracks
        .map(
          (t) => YoutubePlaylistTrack(
            id: t.id,
            title: t.title,
            channel: t.channel,
            thumbnail: t.thumbnail,
            url: t.url,
            durationSeconds: durations[t.id] ?? 0,
          ),
        )
        .toList(growable: false);

    final totalDurationSeconds = enrichedTracks.fold<int>(
      0,
      (sum, t) => sum + t.durationSeconds,
    );

    return YoutubePlaylistInfo(
      id: playlistId,
      title: title,
      channel: channel,
      thumbnail: thumbnail,
      url: 'https://www.youtube.com/playlist?list=$playlistId',
      // Prefer the API-reported count (includes private / deleted
      // entries the items.list call drops); fall back to the actual
      // length when the report is missing.
      trackCount:
          reportedCount > 0 ? reportedCount : enrichedTracks.length,
      totalDurationSeconds: totalDurationSeconds,
      tracks: enrichedTracks,
    );
  }

  /// Walks `playlistItems.list` page by page and returns every track in
  /// the playlist (durations zeroed out — those come from a separate
  /// batched `videos.list` call).
  ///
  /// [fallbackChannel] is used as the per-track channel when the API
  /// did not include `videoOwnerChannelTitle` (some legacy playlists
  /// leave this null).
  static Future<List<YoutubePlaylistTrack>> _fetchAllTracks(
    String playlistId,
    String fallbackChannel,
  ) async {
    final tracks = <YoutubePlaylistTrack>[];
    String? pageToken;
    var safety = 0;

    while (true) {
      // Defensive cap: a playlist with > 5000 entries (100 pages) is
      // almost certainly an automated dump and we'd rather show what we
      // have than hammer the API forever.
      if (safety++ > 100) {
        debugPrint(
          'YoutubePlaylistService: pagination safety cap hit at '
          '${tracks.length} tracks',
        );
        break;
      }

      final query = {
        'part': 'snippet,contentDetails',
        'playlistId': playlistId,
        'maxResults': '50',
        if (pageToken != null) 'pageToken': pageToken,
      };

      final response = await YoutubeApi.get(
        'playlistItems',
        query,
        timeout: _timeout,
      );

      final items = response['items'];
      if (items is List) {
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final track = _parseTrack(raw, fallbackChannel);
          if (track != null) tracks.add(track);
        }
      }

      final next = response['nextPageToken'];
      if (next is! String || next.isEmpty) break;
      pageToken = next;
    }

    return tracks;
  }

  /// Parses one entry from `playlistItems.list`. Returns `null` for
  /// items the renderer can't use (deleted / private videos, missing
  /// videoId, etc.) so the caller can skip them silently.
  static YoutubePlaylistTrack? _parseTrack(
    Map<String, dynamic> raw,
    String fallbackChannel,
  ) {
    final snippet = raw['snippet'];
    final contentDetails = raw['contentDetails'];
    if (snippet is! Map) return null;

    // The canonical place for the videoId in playlistItems is
    // contentDetails.videoId — snippet.resourceId.videoId is also
    // populated but contentDetails wins because it's stable across
    // the API's history.
    String videoId = '';
    if (contentDetails is Map) {
      final v = contentDetails['videoId'];
      if (v is String) videoId = v;
    }
    if (videoId.isEmpty) {
      final resource = snippet['resourceId'];
      if (resource is Map) {
        final v = resource['videoId'];
        if (v is String) videoId = v;
      }
    }
    if (videoId.isEmpty) return null;

    final title = decodeYoutubeText(snippet['title']?.toString() ?? '');
    // Skip the placeholders the API surfaces for entries the user can
    // no longer access. Dropping them keeps the UI clean and prevents
    // the downloader from racking up failures on URLs that will never
    // resolve.
    if (title == 'Deleted video' ||
        title == 'Private video' ||
        title == '[Deleted video]' ||
        title == '[Private video]') {
      return null;
    }

    final channel = decodeYoutubeText(
      (snippet['videoOwnerChannelTitle'] ??
              snippet['channelTitle'] ??
              fallbackChannel)
          .toString(),
    );

    return YoutubePlaylistTrack(
      id: videoId,
      title: title,
      channel: channel,
      thumbnail: pickThumbnailUrl(snippet['thumbnails']),
      url: 'https://www.youtube.com/watch?v=$videoId',
      durationSeconds: 0,
    );
  }

  /// Batched `videos.list?part=contentDetails&id=…` returning a map of
  /// video id → duration in seconds. Empty when [ids] is empty.
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
        // Per-batch failures are non-fatal — the affected tracks just
        // render without a duration label, matching the historical
        // "0:00 → hide" behaviour.
        debugPrint(
          'YoutubePlaylistService: video duration batch failed: $e',
        );
      }
    }
    return result;
  }

  /// Pulls the `list=…` query parameter out of a YouTube playlist URL.
  /// Returns `null` for URLs without a list parameter.
  static String? _extractPlaylistId(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    Uri? uri;
    try {
      uri = Uri.parse(trimmed);
    } catch (_) {
      return null;
    }
    final list = uri.queryParameters['list'];
    if (list != null && list.isNotEmpty) return list;
    return null;
  }
}
