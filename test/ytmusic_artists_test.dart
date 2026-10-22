import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openmusic/services/ytmusic_web.dart';

/// Answers every request with [reply]; nothing leaves the machine.
YtMusicWeb fake(Map<String, dynamic> reply) => YtMusicWeb(
  cookies: '',
  visitorData: '',
  client: MockClient((_) async => http.Response.bytes(utf8.encode(jsonEncode(reply)), 200)),
);

Map<String, dynamic> text(String t) => {'text': t};
Map<String, dynamic> link(String t, String id, String pageType) => {
  'text': t,
  'navigationEndpoint': {
    'browseEndpoint': {
      'browseId': id,
      'browseEndpointContextSupportedConfigs': {
        'browseEndpointContextMusicConfig': {'pageType': pageType},
      },
    },
  },
};
Map<String, dynamic> watch(String t, String videoId) => {
  'text': t,
  'navigationEndpoint': {
    'watchEndpoint': {'videoId': videoId},
  },
};
final dot = text(' • ');

/// A result row as YouTube Music lays it out: title, then subtitle columns.
Map<String, dynamic> row(String title, String videoId, List<List<Map<String, dynamic>>> columns) => {
  'musicResponsiveListItemRenderer': {
    'flexColumns': [
      for (final runs in [
        [watch(title, videoId)],
        ...columns,
      ])
        {
          'musicResponsiveListItemFlexColumnRenderer': {
            'text': {'runs': runs},
          },
        },
    ],
  },
};

void main() {
  test('an upload names the channel that uploaded it, not its views or length', () async {
    final web = fake({
      'contents': [
        row('Tomazacre - TERREMOTO', 'v1', [
          [link('Tomazacre', 'UCtoma', 'MUSIC_PAGE_TYPE_USER_CHANNEL'), dot, text('5.7M views'), dot, text('2:51')],
        ]),
        row('WING vs BLACKROLL', 'v2', [
          [
            text('Video'),
            dot,
            link('Swissbeatbox', 'UCswiss', 'MUSIC_PAGE_TYPE_USER_CHANNEL'),
            dot,
            text('4.1M views'),
          ],
        ]),
      ],
    });
    final rows = await web.searchVideos('beatbox');
    expect(rows.map((t) => t.artist), ['Tomazacre', 'Swissbeatbox']);
    expect(rows.first.duration, const Duration(minutes: 2, seconds: 51));
    expect(rows.map((t) => t.artistId), [null, null], reason: 'an uploader has no artist page to open');
  });

  test('songs under an artist\'s top result get that artist', () async {
    final web = fake({
      'contents': [
        {
          'musicCardShelfRenderer': {
            'title': {
              'runs': [link('Codfish', 'UCcod', 'MUSIC_PAGE_TYPE_ARTIST')],
            },
            'subtitle': {
              'runs': [text('Artist')],
            },
            'contents': [
              row('Boulevard of Broken Dreams', 'v1', [
                [text('Song'), dot, text('2:13')],
                [text('38M plays')],
              ]),
            ],
          },
        },
        row('Poison Dagger', 'v2', [
          [text('Song'), dot, link('D-low', 'UCdlow', 'MUSIC_PAGE_TYPE_ARTIST')],
          [text('1.8M plays')],
        ]),
      ],
    });
    final r = await web.search('codfish');
    expect(r.songs.map((t) => (t.title, t.artist, t.artistId)), [
      ('Boulevard of Broken Dreams', 'Codfish', 'UCcod'),
      ('Poison Dagger', 'D-low', 'UCdlow'),
    ]);
  });

  test('cards list every artist, linked or not, and skip the album and year', () async {
    final web = fake({
      'contents': [
        {
          'musicCarouselShelfRenderer': {
            'header': {
              'musicCarouselShelfBasicHeaderRenderer': {
                'title': {
                  'runs': [text('New music videos')],
                },
              },
            },
            'contents': [
              for (final (id, runs) in [
                (
                  'v1',
                  [
                    text('Adrian'),
                    text(' & '),
                    link('Astrid', 'UCastrid', 'MUSIC_PAGE_TYPE_ARTIST'),
                    dot,
                    text('265K views'),
                  ],
                ),
                ('v2', [link('FireVolk', 'UCfire', 'MUSIC_PAGE_TYPE_USER_CHANNEL'), dot, text('46K views')]),
                (
                  'v3',
                  [
                    text('Song'),
                    dot,
                    link('Codfish', 'UCcod', 'MUSIC_PAGE_TYPE_ARTIST'),
                    dot,
                    link('Fish Man', 'MPREfish', 'MUSIC_PAGE_TYPE_ALBUM'),
                    dot,
                    text('2019'),
                  ],
                ),
              ])
                {
                  'musicTwoRowItemRenderer': {
                    'title': {
                      'runs': [text('Title $id')],
                    },
                    'subtitle': {'runs': runs},
                    'navigationEndpoint': {
                      'watchEndpoint': {'videoId': id},
                    },
                  },
                },
            ],
          },
        },
      ],
    });
    final tracks = (await web.shelves('FEmusic_explore')).single.tracks;
    expect(tracks.map((t) => t.artist), ['Adrian, Astrid', 'FireVolk', 'Codfish']);
    expect(tracks.map((t) => t.artistId), ['UCastrid', null, 'UCcod']);
  });
}
