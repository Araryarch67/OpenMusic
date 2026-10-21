import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openmusic/services/metadata.dart';

void main() {
  http.Response groups(List<Map<String, Object>> g) => http.Response(jsonEncode({'release-groups': g}), 200);
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

  test('takes the first well-matched release group that has a front cover', () async {
    final asked = <String>[];
    final found = await Metadata.findCoverOnline(
      'Daft "Punk"',
      'Discovery',
      client: MockClient((req) async {
        asked.add(req.url.toString());
        if (req.url.host == 'musicbrainz.org') {
          expect(req.url.queryParameters['query'], r'releasegroup:"Discovery" AND artist:"Daft \"Punk\""');
          expect(req.headers['User-Agent'], contains('OpenMusic'));
          return groups([
            {'id': 'no-art', 'score': 100},
            {'id': 'has-art', 'score': 95},
            {'id': 'weak', 'score': 40},
          ]);
        }
        if (req.url.path.contains('no-art')) return http.Response('', 404);
        return http.Response.bytes(jpeg, 200, headers: {'content-type': 'image/jpeg'});
      }),
    );
    expect(found?.bytes, jpeg);
    expect(found?.mime, 'image/jpeg');
    expect(asked.last, 'https://coverartarchive.org/release-group/has-art/front-1200');
  });

  test('null when only weak matches come back', () async {
    final found = await Metadata.findCoverOnline(
      'Someone',
      'Nothing',
      client: MockClient((req) async {
        if (req.url.host == 'musicbrainz.org') {
          return groups([
            {'id': 'x', 'score': 50},
          ]);
        }
        fail('should not fetch art for a weak match');
      }),
    );
    expect(found, isNull);
  });

  test('throws when MusicBrainz is down, so the UI can say so', () {
    expect(
      Metadata.findCoverOnline('a', 'b', client: MockClient((_) async => http.Response('', 503))),
      throwsA(isA<Exception>()),
    );
  });

  test('live: finds a real cover', () async {
    final found = await Metadata.findCoverOnline('Daft Punk', 'Discovery', client: http.Client());
    expect(found, isNotNull);
    expect(found!.bytes.length, greaterThan(50000));
  });
}
