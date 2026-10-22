import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openmusic/services/ytmusic_web.dart';

/// Records what would be sent to YouTube Music; nothing leaves the machine.
({YtMusicWeb web, List<(String, Map<String, dynamic>)> sent}) fake(Map<String, dynamic> Function(String) reply) {
  final sent = <(String, Map<String, dynamic>)>[];
  final client = MockClient((req) async {
    final endpoint = req.url.path.replaceFirst('/youtubei/v1/', '');
    sent.add((endpoint, jsonDecode(req.body) as Map<String, dynamic>));
    expect(req.url.queryParameters.containsKey('key'), isFalse, reason: 'no API key is sent');
    expect(req.headers['authorization'], startsWith('SAPISIDHASH '));
    return http.Response.bytes(utf8.encode(jsonEncode(reply(endpoint))), 200);
  });
  return (web: YtMusicWeb(cookies: '__Secure-3PAPISID=abc; SAPISID=abc', visitorData: 'v', client: client), sent: sent);
}

void main() {
  test('creates a playlist with songs', () async {
    final f = fake((_) => {'playlistId': 'PLnew'});
    final id = await f.web.createPlaylist('Road trip', privacy: PlaylistPrivacy.unlisted, videoIds: ['a', 'b']);
    expect(id, 'PLnew');
    final (endpoint, body) = f.sent.single;
    expect(endpoint, 'playlist/create');
    expect(body['title'], 'Road trip');
    expect(body['privacyStatus'], 'UNLISTED');
    expect(body['videoIds'], ['a', 'b']);
  });

  test('edits use the right actions', () async {
    final f = fake((_) => {'status': 'STATUS_SUCCEEDED'});
    await f.web.addToPlaylist('VLPLx', ['v1']);
    await f.web.removeFromPlaylist('PLx', [(videoId: 'v1', setVideoId: 'row1')]);
    await f.web.renamePlaylist('PLx', 'New name');
    await f.web.setPlaylistPrivacy('PLx', PlaylistPrivacy.public);
    await f.web.movePlaylistItem('PLx', 'row1', 'row2');
    final actions = [for (final (e, b) in f.sent) (e, b['playlistId'], (b['actions'] as List).single as Map)];
    expect(actions.every((a) => a.$1 == 'browse/edit_playlist' && a.$2 == 'PLx'), isTrue, reason: 'VL prefix stripped');
    expect(actions[0].$3, {'action': 'ACTION_ADD_VIDEO', 'addedVideoId': 'v1', 'dedupeOption': 'DEDUPE_OPTION_SKIP'});
    expect(actions[1].$3, {'action': 'ACTION_REMOVE_VIDEO', 'setVideoId': 'row1', 'removedVideoId': 'v1'});
    expect(actions[2].$3, {'action': 'ACTION_SET_PLAYLIST_NAME', 'playlistName': 'New name'});
    expect(actions[3].$3, {'action': 'ACTION_SET_PLAYLIST_PRIVACY', 'playlistPrivacy': 'PUBLIC'});
    expect(actions[4].$3, {
      'action': 'ACTION_MOVE_VIDEO_BEFORE',
      'setVideoId': 'row1',
      'movedSetVideoIdSuccessor': 'row2',
    });
  });

  test('a refused edit is an error', () async {
    final f = fake((_) => {'status': 'STATUS_FAILED'});
    expect(() => f.web.renamePlaylist('PLx', 'x'), throwsA(isA<YtMusicWebError>()));
  });

  test('likes, unlikes and deletes', () async {
    final f = fake((_) => {});
    await f.web.rate('v1', liked: true);
    await f.web.rate('v1', liked: false);
    await f.web.deletePlaylist('VLPLx');
    expect(f.sent.map((s) => s.$1), ['like/like', 'like/removelike', 'playlist/delete']);
    expect(f.sent[0].$2['target'], {'videoId': 'v1'});
    expect(f.sent[2].$2['playlistId'], 'PLx');
  });

  test('reads ownership, privacy and row ids from a playlist page', () async {
    final f = fake(
      (_) => {
        'header': {
          'musicEditablePlaylistDetailHeaderRenderer': {
            'editHeader': {
              'musicPlaylistEditHeaderRenderer': {'privacy': 'PRIVATE'},
            },
          },
        },
        'contents': {
          'musicPlaylistShelfRenderer': {
            'contents': [
              {
                'musicResponsiveListItemRenderer': {
                  'playlistItemData': {'playlistSetVideoId': 'row9', 'videoId': 'v9'},
                  'flexColumns': [
                    {
                      'musicResponsiveListItemFlexColumnRenderer': {
                        'text': {
                          'runs': [
                            {
                              'text': 'Song',
                              'navigationEndpoint': {
                                'watchEndpoint': {'videoId': 'v9'},
                              },
                            },
                          ],
                        },
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      },
    );
    final page = await f.web.playlistPage('PLx');
    expect(page.owned, isTrue);
    expect(page.privacy, PlaylistPrivacy.private);
    expect(page.tracks.single.setVideoId, 'row9');
    expect(f.sent.single.$2['browseId'], 'VLPLx');
  });

  test('sharing a playlist: invite link, join, stop', () async {
    const link = 'https://music.youtube.com/playlist?list=PLx&jct=tok123';
    final f = fake((_) => {'status': 'STATUS_SUCCEEDED', 'collaborationInviteLink': link});
    expect(await f.web.collaborationLink('VLPLx'), link);
    await f.web.joinCollaboration('PLx', 'tok123');
    await f.web.stopCollaboration('PLx');
    final actions = [for (final (e, b) in f.sent) (e, b['playlistId'], (b['actions'] as List).single as Map)];
    expect(actions.every((a) => a.$1 == 'browse/edit_playlist' && a.$2 == 'PLx'), isTrue);
    expect(actions[0].$3, {'action': 'ACTION_CREATE_COLLABORATION_INVITE_LINK'});
    expect(actions[1].$3, {'action': 'ACTION_JOIN_COLLABORATION', 'joinCollaborationToken': 'tok123'});
    expect(actions[2].$3, {'action': 'ACTION_SET_CLOSED_TO_CONTRIBUTIONS', 'closedToContributions': true});
  });

  test('no invite link in the reply is an error', () async {
    final f = fake((_) => {'status': 'STATUS_SUCCEEDED'});
    expect(() => f.web.collaborationLink('PLx'), throwsA(isA<YtMusicWebError>()));
  });

  test('reads invite links and nothing else', () {
    expect(YtMusicWeb.parseInvite(' https://music.youtube.com/playlist?list=PLabc&jct=t-1_x '), (
      playlistId: 'PLabc',
      token: 't-1_x',
    ));
    expect(YtMusicWeb.parseInvite('https://www.youtube.com/playlist?list=VLPLabc&jct=t'), (
      playlistId: 'PLabc',
      token: 't',
    ));
    expect(YtMusicWeb.parseInvite('https://music.youtube.com/playlist?list=PLabc'), isNull, reason: 'no token');
    expect(YtMusicWeb.parseInvite('https://evil.example/playlist?list=PLabc&jct=t'), isNull);
    expect(YtMusicWeb.parseInvite('https://notyoutube.com/playlist?list=PLabc&jct=t'), isNull);
    expect(YtMusicWeb.parseInvite('hello'), isNull);
  });

  test('a playlist with collaborators reads as shared', () async {
    Map<String, dynamic> page(String panel) => {
      'header': {
        'musicResponsiveHeaderRenderer': {
          'facepile': {
            'avatarStackViewModel': {
              'rendererContext': {
                'commandContext': {
                  'onTap': {
                    'innertubeCommand': {
                      'showEngagementPanelEndpoint': {'panelIdentifier': panel},
                    },
                  },
                },
              },
            },
          },
        },
      },
    };
    expect((await fake((_) => page('PAplaylist_collaborate')).web.playlistPage('PLx')).collaborative, isTrue);
    expect((await fake((_) => page('PAsomething_else')).web.playlistPage('PLx')).collaborative, isFalse);
  });

  test('reads a long playlist page after page', () async {
    Map<String, dynamic> row(String id) => {
      'musicResponsiveListItemRenderer': {
        'flexColumns': [
          {
            'musicResponsiveListItemFlexColumnRenderer': {
              'text': {
                'runs': [
                  {
                    'text': 'Song $id',
                    'navigationEndpoint': {
                      'watchEndpoint': {'videoId': id},
                    },
                  },
                ],
              },
            },
          },
        ],
      },
    };
    Map<String, dynamic> more(String token) => {
      'continuationItemRenderer': {
        'continuationEndpoint': {
          'continuationCommand': {'token': token},
        },
      },
    };
    final pages = <Object?, Map<String, dynamic>>{
      null: {
        'contents': {
          'musicPlaylistShelfRenderer': {
            'contents': [row('a'), row('b'), more('t1')],
          },
        },
      },
      't1': {
        'onResponseReceivedActions': [
          {
            'appendContinuationItemsAction': {
              'continuationItems': [row('c'), more('t2')],
            },
          },
        ],
      },
      't2': {
        'onResponseReceivedActions': [
          {
            'appendContinuationItemsAction': {
              'continuationItems': [row('d')],
            },
          },
        ],
      },
    };
    final web = YtMusicWeb(
      cookies: '',
      visitorData: '',
      client: MockClient(
        (req) async =>
            http.Response.bytes(utf8.encode(jsonEncode(pages[(jsonDecode(req.body) as Map)['continuation']])), 200),
      ),
    );
    expect((await web.playlistTracks('PLx')).map((t) => t.videoId), ['a', 'b', 'c', 'd']);
    expect((await web.playlistTracks('PLx', limit: 3)).map((t) => t.videoId), [
      'a',
      'b',
      'c',
    ], reason: 'stops at the limit');
  });

  test('radio parses the up-next queue', () async {
    final f = fake(
      (_) => {
        'contents': {
          'playlistPanelRenderer': {
            'contents': [
              {
                'playlistPanelVideoRenderer': {
                  'videoId': 'r1',
                  'title': {
                    'runs': [
                      {'text': 'Cincin'},
                    ],
                  },
                  'longBylineText': {
                    'runs': [
                      {'text': 'Hindia'},
                      {'text': ' • '},
                      {'text': 'Lagipula Hidup Akan Berakhir'},
                    ],
                  },
                  'lengthText': {
                    'runs': [
                      {'text': '4:27'},
                    ],
                  },
                },
              },
            ],
          },
        },
      },
    );
    final songs = await f.web.radio('seed');
    expect(f.sent.single.$2['playlistId'], 'RDAMVMseed');
    expect(songs.single.title, 'Cincin');
    expect(songs.single.artist, 'Hindia');
    expect(songs.single.duration, const Duration(minutes: 4, seconds: 27));
  });
}
