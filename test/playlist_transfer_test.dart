import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/playlist_transfer.dart';

/// Serves canned pages by URL; nothing leaves the machine.
PlaylistTransfer fake(Map<String, http.Response Function()> pages) => PlaylistTransfer(
  client: MockClient((req) async {
    final page = pages[req.url.toString()];
    return page == null ? http.Response('not here', 404) : page();
  }),
);

http.Response html(String body) => http.Response.bytes(utf8.encode(body), 200);
http.Response json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

Track yt(String id, String title, String artist, int seconds) => Track.youtube(
  videoId: id,
  title: title,
  artist: artist,
  duration: Duration(seconds: seconds),
);

ForeignSong song(String title, String artist, [int? seconds]) => ForeignSong(
  title: title,
  artist: artist,
  duration: seconds == null ? null : Duration(seconds: seconds),
);

void main() {
  test('recognises playlist and album links from each app', () {
    for (final link in [
      'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc',
      'https://open.spotify.com/intl-id/playlist/37i9dQZF1DXcBWIGoYBM5M',
      'https://open.spotify.com/album/4aawyAB9vmqN3uQ7FjRGTy',
      'spotify:playlist:37i9dQZF1DXcBWIGoYBM5M',
      'https://music.apple.com/us/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb',
      'https://music.apple.com/jp/album/some-album/1440857781',
      'https://www.deezer.com/en/playlist/1313621735',
      'https://deezer.com/album/302127',
      'https://link.deezer.com/s/30vLrGvBR3ZY3fFwd2Oey',
      'https://spotify.link/abc123',
    ]) {
      expect(PlaylistTransfer.looksLikeLink(link), isTrue, reason: link);
    }
    for (final link in [
      'https://open.spotify.com/track/3XmwAZpIMNpTJy8faw3ajD',
      'https://open.spotify.com/playlist/short',
      'https://music.youtube.com/playlist?list=PLx',
      'https://www.deezer.com/en/track/1',
      'https://evil.example/playlist/37i9dQZF1DXcBWIGoYBM5M',
      'hello',
    ]) {
      expect(PlaylistTransfer.looksLikeLink(link), isFalse, reason: link);
    }
  });

  test('reads a Spotify playlist and how long it really is', () async {
    final data = {
      'props': {
        'pageProps': {
          'state': {
            'data': {
              'entity': {
                'name': 'Road trip',
                'trackList': [
                  {'title': 'expectations', 'subtitle': 'Olivia Rodrigo, Chappell Roan', 'duration': 223935},
                  {'title': 'A podcast', 'subtitle': 'Someone', 'entityType': 'episode'},
                ],
              },
            },
          },
        },
      },
    };
    final t = fake({
      'https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M': () =>
          html('<html><script id="__NEXT_DATA__" type="application/json">${jsonEncode(data)}</script></html>'),
      'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M': () =>
          html('<meta name="music:song_count" content="150"/>'),
    });
    final p = await t.read('https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=x');
    expect(p.title, 'Road trip');
    expect(p.service, 'Spotify');
    expect(p.total, 150);
    expect(p.songs.single.artist, 'Olivia Rodrigo, Chappell Roan');
    expect(p.songs.single.duration, const Duration(milliseconds: 223935));
  });

  test('reads an Apple Music playlist', () async {
    final data = {
      'data': [
        {
          'data': {
            'sections': [
              {
                'id': 'playlist-detail-header-section - pl.x',
                'items': [
                  {'title': 'Today’s Hits', 'trackCount': 2},
                ],
              },
              {
                'id': 'track-list - pl.x',
                'itemKind': 'trackLockup',
                'items': [
                  {'title': 'expectations', 'artistName': 'Olivia Rodrigo & Chappell Roan', 'duration': 223935},
                  {'title': 'Housewife', 'artistName': 'Tate McRae', 'duration': 180000},
                ],
              },
            ],
          },
        },
      ],
    };
    final t = fake({
      'https://music.apple.com/us/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb': () =>
          html('<script type="application/json" id="serialized-server-data">${jsonEncode(data)}</script>'),
    });
    final p = await t.read('https://music.apple.com/us/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb');
    expect(p.title, 'Today’s Hits');
    expect(p.songs.map((s) => '$s'), ['Olivia Rodrigo, Chappell Roan - expectations', 'Tate McRae - Housewife']);
  });

  test('reads every page of a Deezer playlist', () async {
    Map<String, dynamic> row(int i) => {
      'title': 'Song $i',
      'duration': 200,
      'artist': {'name': 'Artist $i'},
    };
    final t = fake({
      'https://api.deezer.com/playlist/42': () => json({'title': 'Big one', 'nb_tracks': 3}),
      'https://api.deezer.com/playlist/42/tracks?index=0&limit=100': () => json({
        'data': [row(1), row(2)],
        'next': 'https://api.deezer.com/playlist/42/tracks?index=2&limit=100',
      }),
      'https://api.deezer.com/playlist/42/tracks?index=2&limit=100': () => json({
        'data': [row(3)],
      }),
    });
    final p = await t.read('https://www.deezer.com/en/playlist/42');
    expect(p.title, 'Big one');
    expect(p.songs.map((s) => s.title), ['Song 1', 'Song 2', 'Song 3']);
    expect(p.songs.first.duration, const Duration(seconds: 200));
  });

  test('follows a short share link', () async {
    final t = fake({
      'https://link.deezer.com/s/abc': () =>
          http.Response('', 302, headers: {'location': 'https://www.deezer.com/en/playlist/42?utm=share'}),
      'https://api.deezer.com/playlist/42': () => json({'title': 'Shared', 'nb_tracks': 1}),
      'https://api.deezer.com/playlist/42/tracks?index=0&limit=100': () => json({
        'data': [
          {
            'title': 'Song',
            'artist': {'name': 'A'},
          },
        ],
      }),
    });
    expect((await t.read('https://link.deezer.com/s/abc')).title, 'Shared');
  });

  test('a private or missing playlist says so', () async {
    final t = fake({
      'https://api.deezer.com/playlist/1': () => json({
        'error': {'code': 800},
      }),
    });
    expect(() => t.read('https://www.deezer.com/playlist/1'), throwsA(isA<PlaylistTransferError>()));
    expect(
      () => t.read('https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'),
      throwsA(isA<PlaylistTransferError>()),
    );
  });

  group('picks the right song', () {
    test('ignores feat. and remaster tags and prefers the same length', () {
      final pick = PlaylistTransfer.best(
        song('expectations (feat. Chappell Roan)', 'Olivia Rodrigo, Chappell Roan', 224),
        [
          yt('cover', 'expectations', 'Some Cover Band', 224),
          yt('real', 'expectations', 'Olivia Rodrigo, Chappell Roan', 224),
        ],
      );
      expect(pick?.videoId, 'real');
      expect(
        PlaylistTransfer.best(song('Help! - Remastered 2009', 'The Beatles', 138), [
          yt('a', 'Help!', 'The Beatles', 139),
        ])?.videoId,
        'a',
      );
    });

    test('Japanese titles with a romanised suffix', () {
      expect(
        PlaylistTransfer.best(song('運命さがし', 'Macaroni Empitsu', 230), [
          yt('a', '運命さがし - Unmei Sagashi', 'Macaroni Empitsu', 231),
        ])?.videoId,
        'a',
      );
    });

    test('a same-named song by someone else is no match', () {
      expect(
        PlaylistTransfer.best(song('By your side', 'Shota Shimizu', 242), [
          yt('a', 'By Your Side', 'Ben', 153),
          yt('b', 'By Your Side (feat. RAYE)', 'Jonas Blue', 202),
        ]),
        isNull,
      );
    });
  });

  test('matches in order, once each, falls back to videos, lists the rest', () async {
    final songs = [song('One', 'A', 100), song('Two', 'B', 100), song('One', 'A', 100), song('Gone', 'C', 100)];
    var progress = 0;
    final r = await PlaylistTransfer.match(
      songs,
      (q) async => q.startsWith('One') ? [yt('one', 'One', 'A', 100)] : [],
      videos: (q) async => q.startsWith('Two') ? [yt('two', 'Two (Official Video)', 'B', 101)] : [],
      onProgress: (n) => progress = n,
    );
    expect(r.found.map((t) => t.videoId), ['one', 'two']);
    expect(r.found[1].title, 'Two', reason: 'a video keeps the song\'s own names');
    expect(r.missing.map((s) => s.title), ['Gone']);
    expect(progress, 4);
  });
}
