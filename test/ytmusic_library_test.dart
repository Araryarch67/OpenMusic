import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/youtube_music_account.dart';

Track yt(String id) => Track.youtube(videoId: id, title: 'Song $id', artist: 'Artist');

Map<String, dynamic> column(List<Map<String, dynamic>> runs) => {
  'musicResponsiveListItemFlexColumnRenderer': {
    'text': {'runs': runs},
  },
};

Map<String, dynamic> songRow(String id, String row) => {
  'musicResponsiveListItemRenderer': {
    'playlistItemData': {'playlistSetVideoId': row, 'videoId': id},
    'flexColumns': [
      column([
        {
          'text': 'Song $id',
          'navigationEndpoint': {
            'watchEndpoint': {'videoId': id},
          },
        },
      ]),
      column([
        {'text': 'Artist'},
      ]),
    ],
  },
};

/// YouTube Music as far as the library needs it, keeping its own state, so
/// what the app shows can be checked against what it was told.
class FakeYtMusic {
  final playlists = <String, ({String title, List<(String, String)> rows})>{
    'PL1': (title: 'Road trip', rows: [('a', 'row-a'), ('b', 'row-b')]),
  };
  final liked = <String>['l1'];

  /// Times the library's playlist list was read.
  var listReads = 0;

  late final client = MockClient((req) async {
    final endpoint = req.url.path.replaceFirst('/youtubei/v1/', '');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    return http.Response.bytes(utf8.encode(jsonEncode(_answer(endpoint, body))), 200);
  });

  Map<String, dynamic> _answer(String endpoint, Map<String, dynamic> body) {
    switch (endpoint) {
      case 'account/account_menu':
        return {
          'activeAccountHeaderRenderer': {
            'accountName': {'simpleText': 'Me'},
          },
        };
      case 'playlist/create':
        const id = 'PLnew';
        playlists[id] = (
          title: body['title'] as String,
          rows: [for (final v in (body['videoIds'] as List?) ?? const []) (v as String, 'row-$v')],
        );
        return {'playlistId': id};
      case 'playlist/delete':
        playlists.remove(body['playlistId']);
        return {};
      case 'like/like':
        liked.insert(0, (body['target'] as Map)['videoId'] as String);
        return {};
      case 'browse/edit_playlist':
        final p = playlists[body['playlistId']]!;
        final results = [];
        var title = p.title;
        for (final a in (body['actions'] as List).cast<Map<String, dynamic>>()) {
          switch (a['action']) {
            case 'ACTION_ADD_VIDEO':
              final v = a['addedVideoId'] as String;
              if (p.rows.any((r) => r.$1 == v)) continue; // DEDUPE_OPTION_SKIP
              p.rows.add((v, 'row-$v'));
              results.add({
                'playlistEditVideoAddedResultData': {'videoId': v, 'setVideoId': 'row-$v'},
              });
            case 'ACTION_REMOVE_VIDEO':
              p.rows.removeWhere((r) => r.$2 == a['setVideoId']);
            case 'ACTION_SET_PLAYLIST_NAME':
              title = a['playlistName'] as String;
          }
        }
        playlists[body['playlistId'] as String] = (title: title, rows: p.rows);
        return {'status': 'STATUS_SUCCEEDED', 'playlistEditResults': results};
      case 'browse':
        final id = body['browseId'] as String?;
        if (id == 'FEmusic_liked_playlists') {
          listReads++;
          return {
            'gridRenderer': {
              'items': [
                for (final MapEntry(:key, :value) in playlists.entries)
                  {
                    'musicTwoRowItemRenderer': {
                      'title': {
                        'runs': [
                          {
                            'text': value.title,
                            'navigationEndpoint': {
                              'browseEndpoint': {'browseId': 'VL$key'},
                            },
                          },
                        ],
                      },
                      'subtitle': {
                        'runs': [
                          {'text': '${value.rows.length} songs'},
                        ],
                      },
                    },
                  },
              ],
            },
          };
        }
        final rows = id == 'VLLM'
            ? [for (final v in liked) (v, 'row-$v')]
            : (id != null && id.startsWith('VL') ? playlists[id.substring(2)]?.rows : null);
        if (rows == null) return {};
        return {
          'header': {'musicEditablePlaylistDetailHeaderRenderer': {}},
          'contents': {
            'musicPlaylistShelfRenderer': {
              'contents': [for (final (v, row) in rows) songRow(v, row)],
            },
          },
        };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('openmusic-ytlib');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A signed-in account talking to [server], its library loaded.
  Future<YoutubeMusicAccount> signedIn(FakeYtMusic server) async {
    final a = YoutubeMusicAccount();
    expect(
      await a.connectWebSession(cookies: 'SAPISID=x; __Secure-3PAPISID=x', visitorData: 'v', authUser: '0'),
      isTrue,
    );
    await a.library();
    return a;
  }

  test('playlist edits show at once, without reloading the library', () async {
    final server = FakeYtMusic();
    await http.runWithClient(() async {
      final a = await signedIn(server);
      final reads = server.listReads;
      var notified = 0;
      a.addListener(() => notified++);

      final id = await a.createPlaylist('Gym', tracks: [yt('g1')]);
      var lib = await a.library();
      expect(lib.playlists.map((p) => (p.title, p.count)), [('Gym', 1), ('Road trip', 2)]);
      expect(notified, greaterThan(0));

      // A playlist opened once, then a song added to it from anywhere.
      expect((await a.playlistDetails('PL1')).tracks.map((t) => t.videoId), ['a', 'b']);
      expect(await a.addToPlaylist('PL1', [yt('x')]), 1);
      final shown = a.cachedPlaylist('PL1')!;
      expect(shown.tracks.map((t) => t.videoId), ['a', 'b', 'x']);
      expect(shown.rowIds['yt:x'], 'row-x', reason: 'can be removed again straight away');
      lib = await a.library();
      expect(lib.playlists.firstWhere((p) => p.id == 'PL1').count, 3);

      expect(await a.addToPlaylist('PL1', [yt('x')]), 0, reason: 'already in it');
      expect(a.cachedPlaylist('PL1')!.tracks, hasLength(3));

      await a.removeFromPlaylist('PL1', yt('x'), 'row-x');
      expect(a.cachedPlaylist('PL1')!.tracks.map((t) => t.videoId), ['a', 'b']);
      expect((await a.library()).playlists.firstWhere((p) => p.id == 'PL1').count, 2);

      await a.renamePlaylist(id, 'Gym 2');
      expect((await a.library()).playlists.first.title, 'Gym 2');
      await a.deletePlaylist(id);
      expect((await a.library()).playlists.map((p) => p.id), ['PL1']);

      await a.setLiked(yt('z'), true);
      expect((await a.library()).liked.map((t) => t.videoId), ['z', 'l1']);

      expect(server.listReads, reads, reason: 'no reload after an edit');
      // And YouTube Music agrees with what was shown.
      expect(server.playlists.keys, ['PL1']);
      expect(server.playlists['PL1']!.rows.map((r) => r.$1), ['a', 'b']);
      expect(server.liked, ['z', 'l1']);
    }, () => server.client);
  });

  test('the library on screen loads on first look and shows edits at once', () async {
    final server = FakeYtMusic();
    await http.runWithClient(() async {
      final a = YoutubeMusicAccount();
      expect(a.libraryNow, isNull, reason: 'signed out');
      await a.connectWebSession(cookies: 'SAPISID=x; __Secure-3PAPISID=x', visitorData: 'v', authUser: '0');
      final loaded = Completer<void>();
      a.addListener(() {
        if (a.libraryNow != null && !loaded.isCompleted) loaded.complete();
      });
      expect(a.libraryNow, isNull, reason: 'still loading');
      await loaded.future;
      expect(a.libraryNow!.playlists.map((p) => p.title), ['Road trip']);
      await a.createPlaylist('Gym');
      expect(a.libraryNow!.playlists.map((p) => p.title), ['Gym', 'Road trip']);
      await a.signOut();
      expect(a.libraryNow, isNull);
    }, () => server.client);
  });

  test('a playlist opened before shows at once and follows YouTube Music', () async {
    final server = FakeYtMusic();
    await http.runWithClient(() async {
      final a = await signedIn(server);
      expect(a.cachedPlaylist('PL1'), isNull);
      await a.playlistDetails('PL1');
      // A friend added a song in the meantime.
      server.playlists['PL1']!.rows.add(('f', 'row-f'));
      expect(a.cachedPlaylist('PL1')!.tracks, hasLength(2), reason: 'the copy from last time opens instantly');
      var notified = 0;
      a.addListener(() => notified++);
      await a.playlistDetails('PL1');
      expect(a.cachedPlaylist('PL1')!.tracks.map((t) => t.videoId), ['a', 'b', 'f']);
      expect(notified, greaterThan(0));
      expect((await a.library()).playlists.single.count, 3);
    }, () => server.client);
  });
}
