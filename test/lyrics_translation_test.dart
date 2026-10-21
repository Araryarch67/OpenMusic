import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openmusic/services/lyrics_translation.dart';

void main() {
  http.Response json(Object o) => http.Response.bytes(utf8.encode(jsonEncode(o)), 200);

  // Shape of a real dict-chrome-ex reply (2026-10): translated segments, then
  // one part with the romanization in [2] / [3].
  Object google(String translated, String romanized, String lang) => [
    [
      [translated, 'source', null, null, 3],
      [null, null, romanized, romanized],
    ],
    null,
    lang,
  ];

  test('one request gives pronunciation and translation, lined up, each distinct line once', () async {
    final asked = <String>[];
    final extras = await LyricsTranslation.of(
      ['今日もまた始まる', '', 'Baby, give me some time', '今日もまた始まる'],
      to: 'id',
      client: MockClient((req) async {
        asked.add(req.url.queryParameters['q']!);
        expect(req.url.queryParametersAll['dt'], ['t', 'rm']);
        return json(
          google(
            'Hari ini dimulai lagi\n0000\nSayang, beri aku waktu',
            'kyō mo mata hajimaru 0000 bebī, give me some time',
            'ja',
          ),
        );
      }),
    );
    expect(asked, ['今日もまた始まる\n0000\nBaby, give me some time']);
    expect(extras[0].romanized, 'kyō mo mata hajimaru');
    expect(extras[0].translation, 'Hari ini dimulai lagi');
    expect(extras[1], LineExtras.none);
    expect(extras[2].romanized, isNull, reason: 'Latin lines get no pronunciation');
    expect(extras[2].translation, 'Sayang, beri aku waktu');
    expect(extras[3].translation, 'Hari ini dimulai lagi');
  });

  test('no translation when the lyrics are already in the reader\'s language', () async {
    final extras = await LyricsTranslation.of(
      ['Perjalanan membawamu', 'Bertemu denganku'],
      to: 'id',
      client: MockClient((_) async => json(google('Perjalanan membawamu\n0000\nBertemu denganku', '', 'id'))),
    );
    expect(extras.every((e) => e.translation == null && e.romanized == null), isTrue);
  });

  test('Better Lyrics\' service stands in when Google blocks the request', () async {
    var unisonCalls = 0;
    final extras = await LyricsTranslation.of(
      ['黒猫は危険なstreet sign'],
      to: 'id',
      client: MockClient((req) async {
        if (req.url.host == 'translate.googleapis.com') return http.Response('<html><title>Sorry...</title>', 200);
        // The gateway's occasional 502 gets one retry.
        if (unisonCalls++ == 0) return http.Response('error code: 502', 502);
        expect(jsonDecode(req.body), {
          'lines': ['黒猫は危険なstreet sign'],
          'to': 'id',
        });
        return json({
          'lines': [
            {
              'translation': 'Kucing hitam adalah rambu jalan yang berbahaya',
              'romanization': null,
              'needsTranslation': true,
            },
          ],
        });
      }),
    );
    expect(unisonCalls, 2);
    expect(extras.single.translation, 'Kucing hitam adalah rambu jalan yang berbahaya');
    expect(extras.single.romanized, isNull);
  });

  test('throws when neither service answers, and asks again next time', () async {
    final down = MockClient((_) async => http.Response('', 503));
    await expectLater(LyricsTranslation.of(['さよなら'], to: 'id', client: down), throwsA(anything));
    final extras = await LyricsTranslation.of(
      ['さよなら'],
      to: 'id',
      client: MockClient((_) async => json(google('Selamat tinggal', 'sayonara', 'ja'))),
    );
    expect(extras.single.translation, 'Selamat tinggal');
  });

  test('live: Japanese lyrics get romaji and an Indonesian translation', () async {
    final extras = await LyricsTranslation.of(['サイレンが光ったmidnight', '黒猫は危険なstreet sign', 'さよならは 春の香り']);
    expect(extras, hasLength(3));
    expect(extras.every((e) => e.translation != null), isTrue);
    // Romaji comes from Google only; when it blocks us, Better Lyrics still translates.
    if (extras.first.romanized != null) expect(extras.last.romanized, contains('sayonara'));
  });
}
