import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openmusic/services/lyrics.dart';
import 'package:openmusic/services/ytmusic_web.dart';

// Trimmed from real replies (2026-10, "Hati-Hati di Jalan" by Tulus).
Map<String, dynamic> _next() => {
  'contents': {
    'singleColumnMusicWatchNextResultsRenderer': {
      'tabbedRenderer': {
        'watchNextTabbedResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'title': 'Up next',
                'endpoint': {
                  'browseEndpoint': {'browseId': 'MPTRt_upnext'},
                },
              },
            },
            {
              'tabRenderer': {
                'title': 'Lyrics',
                'endpoint': {
                  'browseEndpoint': {'browseId': 'MPLYt_7FNmIeIV9kf-8'},
                },
              },
            },
          ],
        },
      },
    },
  },
};

Map<String, dynamic> _timed() => {
  'contents': {
    'elementRenderer': {
      'newElement': {
        'type': {
          'componentType': {
            'model': {
              'timedLyricsModel': {
                'lyricsData': {
                  'timedLyricsData': [
                    {
                      'lyricLine': '♪',
                      'cueRange': {'startTimeMilliseconds': '0', 'endTimeMilliseconds': '12110'},
                    },
                    {
                      'lyricLine': 'Perjalanan membawamu',
                      'cueRange': {'startTimeMilliseconds': '12110', 'endTimeMilliseconds': '17190'},
                    },
                    {
                      'lyricLine': 'Bertemu denganku',
                      'cueRange': {'startTimeMilliseconds': '17190', 'endTimeMilliseconds': '20340'},
                    },
                  ],
                  'sourceMessage': 'Source: LyricFind',
                },
              },
            },
          },
        },
      },
    },
  },
};

Map<String, dynamic> _plain() => {
  'contents': {
    'sectionListRenderer': {
      'contents': [
        {
          'musicDescriptionShelfRenderer': {
            'description': {
              'runs': [
                {'text': 'Perjalanan membawamu\nBertemu denganku'},
              ],
            },
            'footer': {
              'runs': [
                {'text': 'Source: LyricFind'},
              ],
            },
          },
        },
      ],
    },
  },
};

YtMusicWeb _web(Map<String, dynamic> Function(String endpoint, Map<String, dynamic> body, String? ua) reply) =>
    YtMusicWeb(
      cookies: '',
      visitorData: '',
      client: MockClient((req) async {
        final endpoint = req.url.path.replaceFirst('/youtubei/v1/', '');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(jsonEncode(reply(endpoint, body, req.headers['user-agent']))), 200);
      }),
    );

String _client(Map<String, dynamic> body) => (body['context'] as Map)['client']['clientName'] as String;

void main() {
  test('YouTube Music: timed lines come from the Android client', () async {
    final asked = <String>[];
    final web = _web((endpoint, body, ua) {
      asked.add('$endpoint ${_client(body)}');
      if (endpoint == 'next') return _next();
      expect(body['browseId'], 'MPLYt_7FNmIeIV9kf-8');
      expect(ua, startsWith('com.google.android.apps.youtube.music/'));
      return _timed();
    });
    final l = (await web.lyrics('E7kHvjvU6JY'))!;
    expect(asked, ['next WEB_REMIX', 'browse ANDROID_MUSIC']);
    expect(l.source, 'LyricFind');
    expect(l.lines.map((x) => (x.time.inMilliseconds, x.text)), [
      (0, ''), // the instrumental intro
      (12110, 'Perjalanan membawamu'),
      (17190, 'Bertemu denganku'),
    ]);
  });

  test('YouTube Music: plain text when there are no timed lines', () async {
    final web = _web((endpoint, body, ua) {
      if (endpoint == 'next') return _next();
      return _client(body) == 'ANDROID_MUSIC' ? <String, dynamic>{} : _plain();
    });
    final l = (await web.lyrics('E7kHvjvU6JY'))!;
    expect(l.lines, isEmpty);
    expect(l.plain, 'Perjalanan membawamu\nBertemu denganku');
    expect(l.source, 'LyricFind');
  });

  test('YouTube Music: no Lyrics tab, no lyrics', () async {
    final web = _web((endpoint, body, ua) => {'contents': {}});
    expect(await web.lyrics('E7kHvjvU6JY'), isNull);
  });

  test('TTML (Better Lyrics): lines from syllable spans, background vocals left out', () {
    const ttml =
        '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">'
        '<body dur="4:02.000"><div begin="13.274" end="38.186">'
        '<p begin="13.274" end="17.779"><span begin="13.274" end="13.674">Perja</span>'
        '<span begin="13.674" end="15.347">la</span><span begin="15.347" end="15.787">nan</span> '
        '<span begin="15.787" end="16.004">mem</span><span begin="16.004" end="16.550">ba</span>'
        '<span begin="16.550" end="16.822">wa</span><span begin="16.822" end="17.779">mu</span>'
        '<span ttm:role="x-bg"><span begin="17.0" end="17.5">(ooh)</span></span></p>'
        '<p begin="1:02.5" end="1:05"><span begin="1:02.5" end="1:05">Bertemu</span></p>'
        '<p begin="00:01:10.250"><span>denganku</span></p>'
        '</div></body></tt>';
    final l = Lyrics.parseTtml(ttml, source: 'Better Lyrics');
    expect(l.source, 'Better Lyrics');
    expect(l.lines.map((x) => (x.time.inMilliseconds, x.text)), [
      (13274, 'Perjalanan membawamu'),
      (62500, 'Bertemu'),
      (70250, 'denganku'),
    ]);
  });
}
