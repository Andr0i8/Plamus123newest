// Unit tests for the pure-Dart helpers in `services/youtube_api.dart`.
//
// These cover the parsing logic that drives the YouTube Data API
// integration — duration parsing (ISO 8601), thumbnail picking, and id
// chunking. The rotating HTTP client is exercised separately via
// integration testing because it talks to live URLs.

import 'package:flutter_test/flutter_test.dart';
import 'package:plamus/services/youtube_api.dart';

void main() {
  group('parseIso8601DurationSeconds', () {
    test('parses simple minutes + seconds', () {
      expect(parseIso8601DurationSeconds('PT4M13S'), 4 * 60 + 13);
    });

    test('parses hours + minutes + seconds', () {
      expect(parseIso8601DurationSeconds('PT1H2M3S'), 3723);
    });

    test('parses seconds-only', () {
      expect(parseIso8601DurationSeconds('PT45S'), 45);
    });

    test('parses minutes-only', () {
      expect(parseIso8601DurationSeconds('PT5M'), 300);
    });

    test('parses hours-only', () {
      expect(parseIso8601DurationSeconds('PT2H'), 7200);
    });

    test('parses live-stream sentinel as zero', () {
      expect(parseIso8601DurationSeconds('P0D'), 0);
    });

    test('parses days variant for very long videos', () {
      expect(parseIso8601DurationSeconds('P1DT2H'), 86400 + 7200);
    });

    test('returns 0 for unparseable input', () {
      expect(parseIso8601DurationSeconds(''), 0);
      expect(parseIso8601DurationSeconds('not a duration'), 0);
      expect(parseIso8601DurationSeconds('5:30'), 0);
    });
  });

  group('pickThumbnailUrl', () {
    test('prefers maxres over lower qualities', () {
      final url = pickThumbnailUrl({
        'default': {'url': 'http://default.jpg'},
        'medium': {'url': 'http://medium.jpg'},
        'high': {'url': 'http://high.jpg'},
        'standard': {'url': 'http://standard.jpg'},
        'maxres': {'url': 'http://maxres.jpg'},
      });
      expect(url, 'http://maxres.jpg');
    });

    test('falls through to high when maxres / standard are missing', () {
      final url = pickThumbnailUrl({
        'default': {'url': 'http://default.jpg'},
        'medium': {'url': 'http://medium.jpg'},
        'high': {'url': 'http://high.jpg'},
      });
      expect(url, 'http://high.jpg');
    });

    test('returns empty string when input is not a map', () {
      expect(pickThumbnailUrl(null), '');
      expect(pickThumbnailUrl('foo'), '');
      expect(pickThumbnailUrl(<String, dynamic>{}), '');
    });

    test('skips entries with empty url field', () {
      final url = pickThumbnailUrl({
        'maxres': {'url': ''},
        'high': {'url': 'http://high.jpg'},
      });
      expect(url, 'http://high.jpg');
    });
  });

  group('chunkIds', () {
    test('returns one chunk for under-50 ids', () {
      final chunks = chunkIds(['a', 'b', 'c']).toList();
      expect(chunks, [
        ['a', 'b', 'c']
      ]);
    });

    test('splits 120 ids into 50 + 50 + 20', () {
      final ids = List<String>.generate(120, (i) => 'id$i');
      final chunks = chunkIds(ids).toList();
      expect(chunks.length, 3);
      expect(chunks[0].length, 50);
      expect(chunks[1].length, 50);
      expect(chunks[2].length, 20);
      // No id is dropped or duplicated.
      expect(chunks.expand((c) => c).toList(), ids);
    });

    test('respects custom chunk size', () {
      final ids = ['a', 'b', 'c', 'd', 'e'];
      final chunks = chunkIds(ids, chunkSize: 2).toList();
      expect(chunks, [
        ['a', 'b'],
        ['c', 'd'],
        ['e'],
      ]);
    });

    test('returns nothing for empty input', () {
      expect(chunkIds(<String>[]).toList(), isEmpty);
    });
  });
}
