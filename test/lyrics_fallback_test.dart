import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/lyrics.dart';
import 'package:openmusic/services/ytmusic_web.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A watch page whose Lyrics tab is [browseId], or one without lyrics.
Map<String, dynamic> _next(String? browseId) => {
  'contents': {
    if (browseId != null)
      'tabs': [
        {
          'tabRenderer': {
            'title': 'Lyrics',
            'endpoint': {
              'browseEndpoint': {'browseId': browseId},
            },
          },
        },
      ],
  },
};

Map<String, dynamic> _timed(List<String> lines) => {
  'contents': {
    'timedLyricsData': [
      for (final (i, l) in lines.indexed)
        {
          'lyricLine': l,
          'cueRange': {'startTimeMilliseconds': '${i * 4000}'},
        },
    ],
    'sourceMessage': 'Source: Musixmatch',
  },
};

/// One song row of a YouTube Music search, as `musicResponsiveListItemRenderer`.
Map<String, dynamic> _songRow(String videoId, String title, String artist, String length) => {
  'musicResponsiveListItemRenderer': {
    'flexColumns': [
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {
                'text': title,
                'navigationEndpoint': {
                  'watchEndpoint': {'videoId': videoId},
                },
              },
            ],
          },
        },
      },
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {'text': 'Song'},
              {'text': ' • '},
              {
                'text': artist,
                'navigationEndpoint': {
                  'browseEndpoint': {
                    'browseId': 'UCartist',
                    'browseEndpointContextSupportedConfigs': {
                      'browseEndpointContextMusicConfig': {'pageType': 'MUSIC_PAGE_TYPE_ARTIST'},
                    },
                  },
                },
              },
              {'text': ' • '},
              {'text': length},
            ],
          },
        },
      },
    ],
  },
};

/// Every lyrics service at once: YouTube Music answers from [youtube]; the
/// others have nothing (so only YouTube Music's answers count).
http.Client _services(http.Response Function(String endpoint, Map<String, dynamic> body, bool android) youtube) =>
    MockClient((req) async {
      final u = req.url;
      switch (u.host) {
        case 'music.youtube.com':
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final android = (req.headers['user-agent'] ?? '').startsWith('com.google.android');
          return youtube(u.path.replaceFirst('/youtubei/v1/', ''), body, android);
        case 'lrclib.net':
          return u.path == '/api/search' ? http.Response('[]', 200) : http.Response('', 404);
        case 'music.163.com':
          return http.Response(
            jsonEncode({
              'result': {'songs': []},
            }),
            200,
          );
        default: // Better Lyrics, lyrics.ovh, YouTube's oEmbed
          return http.Response('', 404);
      }
    });

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final upload = Track.youtube(
    videoId: 'upload00001',
    title: 'Codfish | Boulevard of Broken Dreams (Green Day Beatbox Cover)',
    artist: 'Codfish - Boots n\' cats!',
    duration: const Duration(minutes: 3, seconds: 10),
  );

  /// The upload has no Lyrics tab; the catalogue's "Boulevard of Broken Dreams"
  /// by Codfish, [length] long, does.
  http.Response Function(String, Map<String, dynamic>, bool) catalogue(String length) => (endpoint, body, android) {
    switch (endpoint) {
      case 'next':
        return _json(_next(body['videoId'] == 'song0000001' ? 'MPLYsong' : null));
      case 'search':
        return _json({
          'contents': [_songRow('song0000001', 'Boulevard of Broken Dreams', 'Codfish', length)],
        });
      default: // the lyrics page
        return _json(android ? _timed(['♪', 'I walk a lonely road', 'The only one that I have ever known']) : {});
    }
  };

  test('an upload without lyrics gets the song\'s own, timed when it is the same recording', () async {
    final l = await http.runWithClient(() => LyricsService.forTrack(upload), () => _services(catalogue('3:10')));
    expect(l.synced, isTrue);
    expect(l.lines.map((x) => x.text), contains('I walk a lonely road'));
    expect(l.source, 'YouTube Music (Musixmatch)');
  });

  test('another recording of the song gets its words, without times that wouldn\'t fit', () async {
    final other = Track.youtube(
      videoId: 'upload00002',
      title: upload.title,
      artist: upload.artist,
      duration: const Duration(minutes: 3, seconds: 40), // 30 s longer: a live take
    );
    final l = await http.runWithClient(() => LyricsService.forTrack(other), () => _services(catalogue('3:10')));
    expect(l.synced, isFalse);
    expect(l.plain, contains('I walk a lonely road'));
  });

  test('a song with only a few words still has lyrics', () async {
    final song = Track.youtube(videoId: 'beatbox0001', title: 'JOY!!', artist: 'Jairo');
    final l = await http.runWithClient(
      () => LyricsService.forTrack(song),
      () => _services((endpoint, body, android) {
        if (endpoint == 'next') return _json(_next('MPLYjoy'));
        if (endpoint == 'search') return _json({'contents': []});
        return _json(android ? _timed(['♪', 'Joy!']) : {});
      }),
    );
    expect(l.synced, isTrue, reason: 'one sung line is lyrics too');
    expect(l.lines.map((x) => x.text), contains('Joy!'));
  });

  test('timed lyrics refused: the plain ones still show', () async {
    final web = YtMusicWeb(
      cookies: '',
      visitorData: '',
      client: _services((endpoint, body, android) {
        if (endpoint == 'next') return _json(_next('MPLYplain'));
        if (android) return http.Response('', 400);
        return _json({
          'contents': {
            'musicDescriptionShelfRenderer': {
              'description': {
                'runs': [
                  {'text': 'Line one\nLine two'},
                ],
              },
            },
          },
        });
      }),
    );
    final l = (await web.lyrics('somevideo01'))!;
    expect(l.plain, 'Line one\nLine two');
  });

  test('a service that was down doesn\'t leave "no lyrics" behind', () async {
    final song = Track.youtube(videoId: 'flaky000001', title: 'Hello', artist: 'Adele');
    var down = true;
    http.Client services() => _services((endpoint, body, android) {
      if (down) return http.Response('', 429);
      if (endpoint == 'next') return _json(_next('MPLYhello'));
      if (endpoint == 'search') return _json({'contents': []});
      return _json(android ? _timed(['Hello, it\'s me', 'I was wondering']) : {});
    });
    final first = await http.runWithClient(() => LyricsService.forTrack(song), services);
    expect(first.isEmpty, isTrue);
    down = false;
    final again = await http.runWithClient(() => LyricsService.forTrack(song), services);
    expect(again.synced, isTrue, reason: 'asked again, not answered from the first try');
  });
}
