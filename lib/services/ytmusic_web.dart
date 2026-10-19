import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

/// A song row as YouTube Music returns it.
class WebTrack {
  const WebTrack({
    required this.videoId,
    required this.title,
    required this.artist,
    this.duration,
    this.artworkUrl,
    this.setVideoId,
    this.artistId,
  });

  final String videoId;
  final String title;
  final String artist;
  final Duration? duration;
  final String? artworkUrl;

  /// The first artist's channel (`UC…`), when the row links to it.
  final String? artistId;

  /// This row's id inside a playlist (the same song can be in it twice);
  /// removing and moving songs refer to it.
  final String? setVideoId;
}

/// Who can see a playlist.
enum PlaylistPrivacy {
  public('PUBLIC', 'Public'),
  unlisted('UNLISTED', 'Unlisted'),
  private('PRIVATE', 'Private');

  const PlaylistPrivacy(this.api, this.label);
  final String api;
  final String label;

  static PlaylistPrivacy? parse(Object? s) => values.where((v) => v.api == s).firstOrNull;
}

/// A playlist page: its songs, and whether the signed-in account owns it.
class WebPlaylistPage {
  const WebPlaylistPage({required this.tracks, required this.owned, this.privacy, this.description});

  final List<WebTrack> tracks;
  final bool owned;
  final PlaylistPrivacy? privacy;
  final String? description;
}

/// A playlist from the signed-in library.
class WebPlaylist {
  const WebPlaylist({required this.id, required this.title, required this.count, this.thumbnailUrl});

  final String id;
  final String title;
  final int count;
  final String? thumbnailUrl;
}

/// What a search hit opens.
enum WebResultKind { song, artist, album, playlist }

/// One search hit: a song (with [track]) or something to open ([browseId]).
class WebResult {
  const WebResult({
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.thumbnailUrl,
    this.browseId,
    this.track,
  });

  final WebResultKind kind;
  final String title;
  final String subtitle;
  final String? thumbnailUrl;

  /// `UC…` artist, `MPRE…` album, `VL…` playlist; opens with [YtMusicWeb.browseTracks].
  final String? browseId;
  final WebTrack? track;
}

/// YouTube Music's unfiltered search: the top hit, then a few of each kind.
class WebSearch {
  const WebSearch({
    this.top,
    this.songs = const [],
    this.artists = const [],
    this.albums = const [],
    this.playlists = const [],
  });

  final WebResult? top;
  final List<WebTrack> songs;
  final List<WebResult> artists;
  final List<WebResult> albums;
  final List<WebResult> playlists;
}

/// Suggestions while typing: completed searches, and direct hits.
class WebSuggestions {
  const WebSuggestions({this.queries = const [], this.items = const []});

  final List<String> queries;
  final List<WebResult> items;
}

/// An artist the signed-in account follows.
class WebArtist {
  const WebArtist({required this.browseId, required this.name, this.subtitle, this.thumbnailUrl});

  /// The artist's channel (`UC…`); opens with [YtMusicWeb.browseTracks].
  final String browseId;
  final String name;
  final String? subtitle;
  final String? thumbnailUrl;
}

/// The signed-in account, as YouTube Music's own menu shows it.
class WebProfile {
  const WebProfile({this.name, this.email, this.avatarUrl});

  final String? name;
  final String? email;
  final String? avatarUrl;
}

/// An album or playlist card on a public page (home, explore, charts).
class WebCard {
  const WebCard({required this.browseId, required this.title, required this.subtitle, this.thumbnailUrl});

  /// `VL…` for playlists, `MPRE…` for albums; both open with [YtMusicWeb.browseTracks].
  final String browseId;
  final String title;
  final String subtitle;
  final String? thumbnailUrl;
}

/// One carousel of a page: songs, or album / playlist cards.
class WebShelf {
  const WebShelf({required this.title, this.tracks = const [], this.cards = const []});

  final String title;
  final List<WebTrack> tracks;
  final List<WebCard> cards;
}

class YtMusicWebError implements Exception {
  const YtMusicWebError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// YouTube Music's own API (InnerTube), spoken with a browser session: the
/// cookies and page values a WebView login leaves behind. Without cookies
/// ([YtMusicWeb.anonymous]) the public pages and search still work.
///
/// Response shapes follow ytmusicapi (github.com/sigma67/ytmusicapi), which
/// every third-party client mirrors: the `WEB_REMIX` client, an `SAPISIDHASH`
/// authorization built from `__Secure-3PAPISID`, and browse ids such as
/// `FEmusic_liked_playlists`, `VLLM` (Liked music) and `FEmusic_history`.
class YtMusicWeb {
  YtMusicWeb({required this.cookies, required this.visitorData, this.authUser = '0', http.Client? client})
    : _http = client ?? http.Client();

  /// Signed out: home, explore, albums, public playlists and search.
  YtMusicWeb.anonymous() : this(cookies: '', visitorData: '');

  bool get signedIn => cookies.isNotEmpty;

  /// Everything a `Cookie:` header carries for music.youtube.com.
  final String cookies;

  /// `VISITOR_DATA` from the page's ytcfg.
  final String visitorData;

  /// `SESSION_INDEX`: which signed-in Google account this session belongs to.
  final String authUser;

  static const _base = 'https://music.youtube.com/youtubei/v1/';
  static const _origin = 'https://music.youtube.com';

  static const _ua = 'Mozilla/5.0 (X11; Linux x86_64; rv:88.0) Gecko/20100101 Firefox/88.0';

  final http.Client _http;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _http.close();
  }

  Map<String, dynamic> get _context => {
    'context': {
      'client': {
        'clientName': 'WEB_REMIX',
        // ytmusicapi stamps the current date in; the web client does the same.
        'clientVersion': '1.${_today()}.01.00',
        'hl': 'en',
        if (visitorData.isNotEmpty) 'visitorData': visitorData,
      },
      'user': const <String, dynamic>{},
    },
  };

  static String _today() {
    final d = DateTime.now().toUtc();
    return '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  }

  String get _sapisid {
    final m = RegExp(r'(?:^|;\s*)(?:__Secure-3PAPISID|__Secure-1PAPISID|SAPISID)=([^;]+)').firstMatch(cookies);
    final value = m?.group(1);
    if (value == null || value.isEmpty) {
      throw const YtMusicWebError('The session has no SAPISID cookie, so it is not a signed-in session.');
    }
    return value;
  }

  String get _authorization {
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hash = sha1.convert(utf8.encode('$seconds $_sapisid $_origin')).toString();
    return 'SAPISIDHASH ${seconds}_$hash';
  }

  Future<Map<String, dynamic>> _send(String endpoint, Map<String, dynamic> body) async {
    final res = await _http
        .post(
          Uri.parse('$_base$endpoint?prettyPrint=false'),
          headers: {
            'content-type': 'application/json',
            'user-agent': _ua,
            'origin': _origin,
            'x-origin': _origin,
            if (signedIn) ...{'cookie': cookies, 'authorization': _authorization, 'x-goog-authuser': authUser},
            if (visitorData.isNotEmpty) 'x-goog-visitor-id': visitorData,
            'accept-language': 'en-US,en;q=0.9',
          },
          body: jsonEncode({..._context, ...body}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw YtMusicWebError(switch (res.statusCode) {
        401 || 403 => 'The YouTube Music session was refused; sign in again.',
        429 => 'YouTube Music is rate limiting; try again in a minute.',
        _ => 'YouTube Music replied ${res.statusCode}.',
      });
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map<String, dynamic>) throw const YtMusicWebError('Unexpected reply from YouTube Music.');
    return decoded;
  }

  /// The account menu: proves the session works and names the account.
  Future<WebProfile> accountMenu() async {
    final res = await _send('account/account_menu', const {});
    final header = _asMap(_deepFind(res, 'activeAccountHeaderRenderer'));
    if (header == null) {
      throw YtMusicWebError(
        _signedIn(res) ? 'Could not read the account menu.' : 'The session is not signed in to YouTube Music.',
      );
    }
    return WebProfile(
      name: _text(header['accountName']),
      email: _text(header['email']),
      avatarUrl: _lastThumb(_asMap(header['accountPhoto'])?['thumbnails']),
    );
  }

  /// YouTube's own `logged_in` flag from the response context.
  static bool _signedIn(Map<String, dynamic> response) {
    for (final service in _list(
      _asMap(response['responseContext'])?['serviceTrackingParams'],
    ).whereType<Map<String, dynamic>>()) {
      if (service['service'] != 'GFEEDBACK') continue;
      for (final param in _list(service['params']).whereType<Map<String, dynamic>>()) {
        if (param['key'] == 'logged_in') return param['value'] == '1';
      }
    }
    return false;
  }

  /// Playlists in the user's library. "Liked music" is left out on purpose;
  /// the app shows it as its own collection.
  Future<List<WebPlaylist>> libraryPlaylists({int limit = 200}) async {
    final res = await _send('browse', const {'browseId': 'FEmusic_liked_playlists'});
    final grid = _asMap(_deepFind(res, 'gridRenderer'));
    if (grid == null) return const [];
    final out = <WebPlaylist>[];
    void take(Object? items) {
      for (final item in _list(items)) {
        final row = _asMap(_asMap(item)?['musicTwoRowItemRenderer']);
        final playlist = row == null ? null : _playlistOf(row);
        // Liked music has its own collection; "Episodes for later" (SE) can't hold songs.
        if (playlist != null && playlist.id != 'LM' && playlist.id != 'SE') out.add(playlist);
      }
    }

    take(grid['items']);
    var token = _nextToken(grid);
    while (token != null && out.length < limit) {
      final page = await _send('browse', {'continuation': token});
      final items = _continuationItems(page);
      if (items.isEmpty) break;
      take(items);
      token = _nextToken({'items': items});
    }
    return out;
  }

  /// Every song of a playlist (playlist ids like `LM` for Liked music).
  Future<List<WebTrack>> playlistTracks(String playlistId, {int limit = 500}) =>
      browseTracks('VL$playlistId', limit: limit);

  /// A playlist with what's needed to edit it (ownership, privacy, row ids).
  Future<WebPlaylistPage> playlistPage(String playlistId, {int limit = 500}) async {
    final res = await _send('browse', {'browseId': 'VL$playlistId'});
    final editable = _asMap(_deepFind(res, 'musicEditablePlaylistDetailHeaderRenderer'));
    final edit = _asMap(_deepFind(editable, 'musicPlaylistEditHeaderRenderer'));
    return WebPlaylistPage(
      tracks: await _tracksOf(res, limit),
      owned: editable != null,
      privacy: PlaylistPrivacy.parse(edit?['privacy']),
      description: _text(edit?['description']),
    );
  }

  // ── Library editing (signed in) ──────────────────────────────────────────
  // Request shapes follow ytmusicapi's create_playlist / edit_playlist /
  // add_playlist_items / remove_playlist_items / delete_playlist / rate_song.

  /// Creates a playlist and returns its id.
  Future<String> createPlaylist(
    String title, {
    String description = '',
    PlaylistPrivacy privacy = PlaylistPrivacy.private,
    List<String> videoIds = const [],
  }) async {
    final res = await _send('playlist/create', {
      'title': title,
      'description': description,
      'privacyStatus': privacy.api,
      if (videoIds.isNotEmpty) 'videoIds': videoIds,
    });
    final id = res['playlistId'];
    if (id is! String) throw const YtMusicWebError('YouTube Music did not create the playlist.');
    return id;
  }

  Future<void> _edit(String playlistId, List<Map<String, dynamic>> actions) async {
    final res = await _send('browse/edit_playlist', {
      'playlistId': playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId,
      'actions': actions,
    });
    final status = res['status'];
    if (status is String && !status.contains('SUCCEEDED')) {
      throw YtMusicWebError('YouTube Music refused the change ($status).');
    }
  }

  Future<void> renamePlaylist(String playlistId, String title) => _edit(playlistId, [
    {'action': 'ACTION_SET_PLAYLIST_NAME', 'playlistName': title},
  ]);

  Future<void> setPlaylistDescription(String playlistId, String description) => _edit(playlistId, [
    {'action': 'ACTION_SET_PLAYLIST_DESCRIPTION', 'playlistDescription': description},
  ]);

  Future<void> setPlaylistPrivacy(String playlistId, PlaylistPrivacy privacy) => _edit(playlistId, [
    {'action': 'ACTION_SET_PLAYLIST_PRIVACY', 'playlistPrivacy': privacy.api},
  ]);

  /// Adds songs to the end; ones already in the playlist are skipped.
  Future<void> addToPlaylist(String playlistId, List<String> videoIds) => _edit(playlistId, [
    for (final id in videoIds) {'action': 'ACTION_ADD_VIDEO', 'addedVideoId': id, 'dedupeOption': 'DEDUPE_OPTION_SKIP'},
  ]);

  /// Removes rows (see [WebTrack.setVideoId]).
  Future<void> removeFromPlaylist(String playlistId, List<({String videoId, String setVideoId})> rows) => _edit(
    playlistId,
    [
      for (final r in rows) {'action': 'ACTION_REMOVE_VIDEO', 'setVideoId': r.setVideoId, 'removedVideoId': r.videoId},
    ],
  );

  /// Moves a row so it sits right before [beforeSetVideoId] (null: to the end).
  Future<void> movePlaylistItem(String playlistId, String setVideoId, String? beforeSetVideoId) => _edit(playlistId, [
    {'action': 'ACTION_MOVE_VIDEO_BEFORE', 'setVideoId': setVideoId, 'movedSetVideoIdSuccessor': ?beforeSetVideoId},
  ]);

  Future<void> deletePlaylist(String playlistId) async {
    await _send('playlist/delete', {'playlistId': playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId});
  }

  /// Follows (subscribes to) an artist's channel, or stops following it.
  Future<void> setFollowing(String channelId, {required bool following}) async {
    await _send(following ? 'subscription/subscribe' : 'subscription/unsubscribe', {
      'channelIds': [channelId],
    });
  }

  /// Likes a song (it lands in "Liked music"), or clears the rating.
  Future<void> rate(String videoId, {required bool liked}) async {
    await _send(liked ? 'like/like' : 'like/removelike', {
      'target': {'videoId': videoId},
    });
  }

  /// YouTube Music's "Up next" radio for a song: what the app itself queues
  /// after it (personalised when signed in). `RDAMVM<id>` is the song's radio
  /// playlist; the first entry is the seed song itself.
  Future<List<WebTrack>> radio(String videoId) async {
    final res = await _send('next', {
      'videoId': videoId,
      'playlistId': 'RDAMVM$videoId',
      'isAudioOnly': true,
      'enablePersistentPlaylistPanel': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
      'watchEndpointMusicSupportedConfigs': {
        'watchEndpointMusicConfig': {'hasPersistentPlaylistPanel': true, 'musicVideoType': 'MUSIC_VIDEO_TYPE_ATV'},
      },
    });
    final panel = _asMap(_deepFind(res, 'playlistPanelRenderer'));
    return [
      for (final item in _list(panel?['contents']))
        if (_asMap(_deepFind(item, 'playlistPanelVideoRenderer')) case final row?) ?_panelSong(row),
    ];
  }

  /// A queue row: "Artist • Album • Year" under the title.
  static WebTrack? _panelSong(Map<String, dynamic> row) {
    final id = row['videoId'];
    final title = _text(row['title']);
    if (id is! String || title == null) return null;
    final byline = _text(row['longBylineText']) ?? _text(row['shortBylineText']) ?? '';
    return WebTrack(
      videoId: id,
      title: title,
      artist: byline.split(' • ').first.trim(),
      duration: _duration(_text(row['lengthText'])),
      artworkUrl: _lastThumb(_at(row, const ['thumbnail', 'thumbnails'])),
    );
  }

  /// Every song of a playlist (`VL…`) or album (`MPRE…`) page. Album rows carry
  /// neither artist nor artwork; both come from the page header instead.
  Future<List<WebTrack>> browseTracks(String browseId, {int limit = 500}) async {
    final res = await _send('browse', {'browseId': browseId});
    // An artist page shows a few top songs; "Show all" opens the full list.
    if (browseId.startsWith('UC')) {
      final all = _at(_deepFind(res, 'musicShelfRenderer'), const [
        'bottomEndpoint', 'browseEndpoint', 'browseId', //
      ]);
      if (all is String) return browseTracks(all, limit: limit);
    }
    return _tracksOf(res, limit);
  }

  /// Artists the account follows (YouTube Music's library "Subscriptions").
  Future<List<WebArtist>> followedArtists({int limit = 500}) async {
    final res = await _send('browse', const {'browseId': 'FEmusic_library_corpus_artists'});
    final shelf = _asMap(_deepFind(res, 'musicShelfRenderer'));
    if (shelf == null) return const [];
    final out = <WebArtist>[];
    void take(Object? items) {
      for (final item in _list(items)) {
        final row = _asMap(_asMap(item)?['musicResponsiveListItemRenderer']);
        final artist = row == null ? null : artistOf(row);
        if (artist != null) out.add(artist);
      }
    }

    take(shelf['contents']);
    var token = _nextToken(shelf);
    while (token != null && out.length < limit) {
      final page = await _send('browse', {'continuation': token});
      final items = _continuationItems(page);
      if (items.isEmpty) break;
      take(items);
      token = _nextToken({'items': items});
    }
    return out;
  }

  /// One row of the subscriptions list: name, channel id, "N subscribers".
  @visibleForTesting
  static WebArtist? artistOf(Map<String, dynamic> row) {
    final browseId = _at(row, const ['navigationEndpoint', 'browseEndpoint', 'browseId']);
    final name = _firstRunText(_list(row['flexColumns']).firstOrNull);
    if (browseId is! String || !browseId.startsWith('UC') || name == null) return null;
    final columns = _list(row['flexColumns']);
    return WebArtist(
      browseId: browseId,
      name: name,
      subtitle: columns.length > 1
          ? _text(_at(columns[1], const ['musicResponsiveListItemFlexColumnRenderer', 'text']))
          : null,
      thumbnailUrl: _lastThumb(_at(row, const ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
    );
  }

  Future<List<WebTrack>> _tracksOf(Map<String, dynamic> res, int limit) async {
    final shelf = _asMap(_deepFind(res, 'musicPlaylistShelfRenderer')) ?? _asMap(_deepFind(res, 'musicShelfRenderer'));
    if (shelf == null) return const [];
    final header = _asMap(_deepFind(res, 'musicResponsiveHeaderRenderer'));
    final headerArtist = _text(header?['straplineTextOne']) ?? '';
    final headerArt = _lastThumb(_at(header, const ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
    final out = <WebTrack>[];
    void take(Object? items) {
      for (final item in _list(items)) {
        final row = _asMap(_asMap(item)?['musicResponsiveListItemRenderer']);
        final track = row == null ? null : _songOf(row);
        if (track == null) continue;
        out.add(
          WebTrack(
            videoId: track.videoId,
            title: track.title,
            artist: track.artist.isEmpty ? headerArtist : track.artist,
            duration: track.duration,
            artworkUrl: track.artworkUrl ?? headerArt,
            setVideoId: _at(row, const ['playlistItemData', 'playlistSetVideoId']) as String?,
            artistId: track.artistId,
          ),
        );
      }
    }

    take(shelf['contents'] ?? shelf['items']);
    var token = _nextToken(shelf);
    while (token != null && out.length < limit) {
      final page = await _send('browse', {'continuation': token});
      final items = _continuationItems(page);
      if (items.isEmpty) break;
      take(items);
      token = _nextToken({'items': items});
    }
    return out;
  }

  /// The carousels of a browse page: `FEmusic_home` (personal when signed in),
  /// `FEmusic_explore`, `FEmusic_charts`. Artist, mood and genre carousels are
  /// left out; there is nothing in the app to open them with.
  Future<List<WebShelf>> shelves(String browseId) async {
    final res = await _send('browse', {'browseId': browseId});
    final out = <WebShelf>[];
    for (final node in _deepFindAll(res, 'musicCarouselShelfRenderer')) {
      final shelf = _asMap(node);
      final title = _text(_at(shelf, const ['header', 'musicCarouselShelfBasicHeaderRenderer', 'title']));
      if (shelf == null || title == null) continue;
      final tracks = <WebTrack>[];
      final cards = <WebCard>[];
      for (final item in _list(shelf['contents'])) {
        final row = _asMap(_asMap(item)?['musicResponsiveListItemRenderer']);
        final two = _asMap(_asMap(item)?['musicTwoRowItemRenderer']);
        if (row != null) {
          final t = _songOf(row);
          if (t != null) tracks.add(t);
        } else if (two != null) {
          final watch = _at(two, const ['navigationEndpoint', 'watchEndpoint', 'videoId']);
          if (watch is String) {
            final t = _twoRowSong(two, watch);
            if (t != null) tracks.add(t);
          } else {
            final card = _cardOf(two);
            if (card != null) cards.add(card);
          }
        }
      }
      if (tracks.isNotEmpty || cards.isNotEmpty) out.add(WebShelf(title: title, tracks: tracks, cards: cards));
    }
    return out;
  }

  /// Everything matching [query]: the top result and a few songs, artists,
  /// albums and playlists (YouTube Music's "All" tab).
  Future<WebSearch> search(String query) async {
    final res = await _send('search', {'query': query});
    WebResult? top;
    final card = _asMap(_deepFind(res, 'musicCardShelfRenderer'));
    if (card != null) top = _topResultOf(card);
    final songs = <WebTrack>[], artists = <WebResult>[], albums = <WebResult>[], playlists = <WebResult>[];
    // Rows sit in shelves or item sections depending on the layout YouTube
    // serves; take every result row wherever it is, once.
    final seen = <String>{};
    for (final node in _deepFindAll(res, 'musicResponsiveListItemRenderer')) {
      final hit = _asMap(node) == null ? null : resultOf(_asMap(node)!);
      if (hit == null || !seen.add(hit.browseId ?? hit.track!.videoId)) continue;
      switch (hit.kind) {
        case WebResultKind.song:
          songs.add(hit.track!);
        case WebResultKind.artist:
          artists.add(hit);
        case WebResultKind.album:
          albums.add(hit);
        case WebResultKind.playlist:
          playlists.add(hit);
      }
    }
    return WebSearch(top: top, songs: songs, artists: artists, albums: albums, playlists: playlists);
  }

  /// Search params per filter chip, as ytmusicapi builds them.
  static const _filterParams = {
    WebResultKind.song: 'EgWKAQIIAWoKEAoQCRADEAQQBQ%3D%3D',
    WebResultKind.artist: 'EgWKAQIgAWoKEAoQCRADEAQQBQ%3D%3D',
    WebResultKind.album: 'EgWKAQIYAWoKEAoQCRADEAQQBQ%3D%3D',
    WebResultKind.playlist: 'EgWKAQIoAWoKEAoQCRADEAQQBQ%3D%3D',
  };

  /// Only artists, albums or playlists matching [query] (one filter chip).
  Future<List<WebResult>> searchOnly(String query, WebResultKind kind) async {
    final res = await _send('search', {'query': query, 'params': _filterParams[kind]});
    return [
      for (final node in _deepFindAll(res, 'musicResponsiveListItemRenderer'))
        if (_asMap(node) case final row?)
          if (resultOf(row) case final hit? when hit.kind == kind) hit,
    ];
  }

  /// What the search box offers while typing.
  Future<WebSuggestions> suggestions(String input) async {
    final res = await _send('music/get_search_suggestions', {'input': input});
    final queries = <String>[];
    for (final node in _deepFindAll(res, 'searchSuggestionRenderer')) {
      final q =
          _at(node, const ['navigationEndpoint', 'searchEndpoint', 'query']) ?? _text(_asMap(node)?['suggestion']);
      if (q is String && q.isNotEmpty) queries.add(q);
    }
    final items = [
      for (final node in _deepFindAll(res, 'musicResponsiveListItemRenderer'))
        if (_asMap(node) case final row?) ?resultOf(row),
    ];
    return WebSuggestions(queries: queries, items: items);
  }

  /// One result row of any kind. Songs and videos play; the rest open.
  @visibleForTesting
  static WebResult? resultOf(Map<String, dynamic> row) {
    final thumb = _lastThumb(_at(row, const ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
    final endpoint = _asMap(_at(row, const ['navigationEndpoint', 'browseEndpoint']));
    if (endpoint != null) {
      final kind = _kindOf(endpoint);
      final browseId = endpoint['browseId'];
      final title = _firstRunText(_list(row['flexColumns']).firstOrNull);
      if (kind == null || browseId is! String || title == null) return null;
      final columns = _list(row['flexColumns']);
      return WebResult(
        kind: kind,
        title: title,
        subtitle: columns.length > 1
            ? _text(_at(columns[1], const ['musicResponsiveListItemFlexColumnRenderer', 'text'])) ?? ''
            : '',
        thumbnailUrl: thumb,
        browseId: browseId,
      );
    }
    final song = _songOf(row);
    if (song == null) return null;
    final columns = _list(row['flexColumns']);
    return WebResult(
      kind: WebResultKind.song,
      title: song.title,
      subtitle: columns.length > 1
          ? _text(_at(columns[1], const ['musicResponsiveListItemFlexColumnRenderer', 'text'])) ?? song.artist
          : song.artist,
      thumbnailUrl: thumb,
      track: song,
    );
  }

  static WebResultKind? _kindOf(Map<String, dynamic> browseEndpoint) => switch (_at(browseEndpoint, const [
    'browseEndpointContextSupportedConfigs',
    'browseEndpointContextMusicConfig',
    'pageType',
  ])) {
    'MUSIC_PAGE_TYPE_ARTIST' => WebResultKind.artist,
    'MUSIC_PAGE_TYPE_ALBUM' => WebResultKind.album,
    'MUSIC_PAGE_TYPE_PLAYLIST' => WebResultKind.playlist,
    _ => null,
  };

  /// The big "Top result" card.
  static WebResult? _topResultOf(Map<String, dynamic> card) {
    final title = _text(card['title']);
    final run = _asMap(_list(_asMap(card['title'])?['runs']).firstOrNull);
    if (title == null || run == null) return null;
    final thumb = _lastThumb(_at(card, const ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
    final subtitle = _text(card['subtitle']) ?? '';
    final browse = _asMap(_at(run, const ['navigationEndpoint', 'browseEndpoint']));
    if (browse != null) {
      final kind = _kindOf(browse);
      final id = browse['browseId'];
      if (kind == null || id is! String) return null;
      return WebResult(kind: kind, title: title, subtitle: subtitle, thumbnailUrl: thumb, browseId: id);
    }
    final videoId = _at(run, const ['navigationEndpoint', 'watchEndpoint', 'videoId']);
    if (videoId is! String) return null;
    final artistRun = _list(_asMap(card['subtitle'])?['runs']).whereType<Map<String, dynamic>>().where(_isArtistRun);
    final artistId = _at(artistRun.firstOrNull, const ['navigationEndpoint', 'browseEndpoint', 'browseId']);
    return WebResult(
      kind: WebResultKind.song,
      title: title,
      subtitle: subtitle,
      thumbnailUrl: thumb,
      track: WebTrack(
        videoId: videoId,
        title: title,
        artist: artistRun.map((r) => r['text'] as String).join(', '),
        artworkUrl: thumb,
        artistId: artistId is String ? artistId : null,
      ),
    );
  }

  /// Songs matching [query], using YouTube Music's own "Songs" filter.
  Future<List<WebTrack>> searchSongs(String query) async {
    // The params value is the "Songs" chip, as ytmusicapi sends it.
    final res = await _send('search', {'query': query, 'params': 'EgWKAQIIAWoKEAoQCRADEAQQBQ%3D%3D'});
    return [
      for (final node in _deepFindAll(res, 'musicResponsiveListItemRenderer'))
        if (_asMap(node) case final row?) ?_songOf(row),
    ];
  }

  static WebTrack? _twoRowSong(Map<String, dynamic> data, String videoId) {
    final title = _text(data['title']);
    if (title == null) return null;
    final artists = [
      for (final run in _list(_at(data, const ['subtitle', 'runs'])).whereType<Map<String, dynamic>>())
        if (_isArtistRun(run)) run['text'] as String,
    ];
    return WebTrack(
      videoId: videoId,
      title: title,
      artist: artists.join(', '),
      artworkUrl: _lastThumb(
        _at(data, const ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']),
      ),
    );
  }

  static WebCard? _cardOf(Map<String, dynamic> data) {
    final endpoint = _asMap(_at(data, const ['navigationEndpoint', 'browseEndpoint']));
    final browseId = endpoint?['browseId'];
    final pageType = _at(endpoint, const [
      'browseEndpointContextSupportedConfigs',
      'browseEndpointContextMusicConfig',
      'pageType',
    ]);
    final title = _text(data['title']);
    if (browseId is! String || title == null) return null;
    if (pageType != 'MUSIC_PAGE_TYPE_ALBUM' && pageType != 'MUSIC_PAGE_TYPE_PLAYLIST') return null;
    return WebCard(
      browseId: browseId,
      title: title,
      subtitle: _text(data['subtitle']) ?? '',
      thumbnailUrl: _lastThumb(
        _at(data, const ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']),
      ),
    );
  }

  /// The account's play history, newest first. The page groups it into shelves
  /// ("Today", "Yesterday", ...); the shelves are read in that order.
  Future<List<WebTrack>> history({int limit = 30}) async {
    final res = await _send('browse', const {'browseId': 'FEmusic_history'});
    final sections = _list(_asMap(_deepFind(res, 'sectionListRenderer'))?['contents']);
    final out = <WebTrack>[];
    for (final section in sections) {
      final shelf = _asMap(_asMap(section)?['musicShelfRenderer']);
      if (shelf == null) continue;
      for (final item in _list(shelf['contents'])) {
        final row = _asMap(_asMap(item)?['musicResponsiveListItemRenderer']);
        final track = row == null ? null : _songOf(row);
        if (track != null) out.add(track);
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  /// One song row. Playlists, albums and history order their columns
  /// differently, so title and artist come from the navigation endpoints (the
  /// way ytmusicapi does it) instead of fixed column numbers.
  static WebTrack? _songOf(Map<String, dynamic> data) {
    var videoId = _at(data, const ['playButton', 'playNavigationEndpoint', 'watchEndpoint', 'videoId']);
    videoId ??= _at(data, const ['navigationEndpoint', 'watchEndpoint', 'videoId']);

    String? title;
    String? artistId;
    final artists = <String>[];
    for (final column in _list(data['flexColumns'])) {
      final runs = _list(_at(column, const ['musicResponsiveListItemFlexColumnRenderer', 'text', 'runs']))
          .whereType<Map<String, dynamic>>()
          .toList();
      if (runs.isEmpty) continue;
      final first = runs.first;
      if (title == null && _asMap(first['navigationEndpoint'])?['watchEndpoint'] != null) {
        title = first['text'] as String?;
        videoId ??= _at(first, const ['navigationEndpoint', 'watchEndpoint', 'videoId']);
      }
      if (artists.isEmpty) {
        artists.addAll([
          for (final run in runs)
            if (_isArtistRun(run)) run['text'] as String,
        ]);
        for (final run in runs.where(_isArtistRun)) {
          final id = _at(run, const ['navigationEndpoint', 'browseEndpoint', 'browseId']);
          if (id is String && id.startsWith('UC')) {
            artistId ??= id;
            break;
          }
        }
      }
    }
    title ??= _firstRunText(_list(data['flexColumns']).firstOrNull);
    if (title == null || videoId is! String) return null;
    return WebTrack(
      videoId: videoId,
      title: title.trim(),
      artist: artists.isEmpty ? _looseArtist(data) : artists.join(', '),
      duration:
          _duration(
            _text(_at(data, const ['fixedColumns', 0, 'musicResponsiveListItemFixedColumnRenderer', 'text'])),
          ) ??
          _flexDuration(data),
      artworkUrl: _lastThumb(_at(data, const ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
      artistId: artistId,
    );
  }

  /// Search rows put the length in a subtitle run ("Artist • Album • 3:45").
  static Duration? _flexDuration(Map<String, dynamic> data) {
    for (final column in _list(data['flexColumns'])) {
      for (final run in _list(_at(column, const ['musicResponsiveListItemFlexColumnRenderer', 'text', 'runs']))) {
        final text = _asMap(run)?['text'];
        if (text is String && RegExp(r'^\d+(:\d\d){1,2}$').hasMatch(text.trim())) return _duration(text.trim());
      }
    }
    return null;
  }

  static bool _isArtistRun(Map<String, dynamic> run) {
    if (run['text'] is! String) return false;
    final pageType = _at(run, const [
      'navigationEndpoint',
      'browseEndpoint',
      'browseEndpointContextSupportedConfigs',
      'browseEndpointContextMusicConfig',
      'pageType',
    ]);
    return pageType == 'MUSIC_PAGE_TYPE_ARTIST' || pageType == 'MUSIC_PAGE_TYPE_UNKNOWN';
  }

  /// Fallback when no column marks its links as artists: the second column
  /// minus separators. Rare, but old rows and uploads hit it.
  static String _looseArtist(Map<String, dynamic> data) {
    final columns = _list(data['flexColumns']);
    if (columns.length < 2) return '';
    return _list(_at(columns[1], const ['musicResponsiveListItemFlexColumnRenderer', 'text', 'runs']))
        .whereType<Map<String, dynamic>>()
        .map((run) => run['text'])
        .whereType<String>()
        .where((t) => t.trim().isNotEmpty && t.trim() != '•' && t.trim() != '&' && t.trim() != ',')
        .join(', ');
  }

  /// One playlist card from the library grid.
  static WebPlaylist? _playlistOf(Map<String, dynamic> data) {
    final browseId = _at(data, const ['title', 'runs', 0, 'navigationEndpoint', 'browseEndpoint', 'browseId']);
    final title = _text(data['title']);
    if (browseId is! String || title == null || browseId.isEmpty) return null;
    final count = int.tryParse(RegExp(r'\d+').firstMatch(_text(data['subtitle']) ?? '')?.group(0) ?? '') ?? 0;
    return WebPlaylist(
      id: browseId.startsWith('VL') ? browseId.substring(2) : browseId,
      title: title,
      count: count,
      thumbnailUrl: _lastThumb(
        _at(data, const ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']),
      ),
    );
  }

  /// The token for the next page, if there is one. Newer replies hang it on a
  /// trailing continuation item, older ones on a `continuations` list.
  static String? _nextToken(Object? renderer) {
    final map = _asMap(renderer);
    final legacy = _at(map, const ['continuations', 0, 'nextContinuationData', 'continuation']);
    if (legacy is String && legacy.isNotEmpty) return legacy;
    final token = _at(_asMap(_list(map?['contents'] ?? map?['items']).lastOrNull), const [
      'continuationItemRenderer',
      'continuationEndpoint',
      'continuationCommand',
      'token',
    ]);
    return token is String && token.isNotEmpty ? token : null;
  }

  /// Items from a continuation reply, in either of the two shapes YouTube
  /// Music uses: `continuationContents` or appended actions.
  static List<Object?> _continuationItems(Map<String, dynamic> response) {
    final contents = _asMap(response['continuationContents']);
    if (contents != null && contents.isNotEmpty) {
      final sub = contents.values.first;
      final items = _at(sub, const ['items']) ?? _at(sub, const ['contents']);
      if (items is List) return items;
    }
    return _list(
      _at(response, const ['onResponseReceivedActions', 0, 'appendContinuationItemsAction', 'continuationItems']),
    );
  }

  static Duration? _duration(String? text) {
    final parts = text?.split(':').map(int.tryParse).toList();
    if (parts == null || parts.length < 2 || parts.length > 3 || parts.any((p) => p == null)) return null;
    return parts.length == 2
        ? Duration(minutes: parts[0]!, seconds: parts[1]!)
        : Duration(hours: parts[0]!, minutes: parts[1]!, seconds: parts[2]!);
  }

  static String? _text(Object? node) {
    final map = _asMap(node);
    if (map == null) return null;
    final simple = map['simpleText'];
    if (simple is String) return simple;
    final runs = _list(map['runs']);
    if (runs.isEmpty) return null;
    return runs.whereType<Map<String, dynamic>>().map((run) => run['text']).whereType<String>().join();
  }

  static String? _firstRunText(Object? column) {
    final runs = _list(_at(column, const ['musicResponsiveListItemFlexColumnRenderer', 'text', 'runs']));
    final first = _asMap(runs.firstOrNull);
    return first?['text'] as String?;
  }

  static String? _lastThumb(Object? list) {
    if (list is! List) return null;
    String? url;
    for (final item in list) {
      final value = _asMap(item)?['url'];
      if (value is String) url = value;
    }
    // Song rows only list 60/120px sizes; googleusercontent serves any size on request.
    return url?.split('?').first.replaceFirst(RegExp(r'=w\d+-h\d+'), '=w544-h544');
  }

  static Object? _at(Object? node, List<Object> path) {
    var current = node;
    for (final key in path) {
      if (current is Map) {
        current = current[key];
      } else if (current is List && key is int && key >= 0 && key < current.length) {
        current = current[key];
      } else {
        return null;
      }
      if (current == null) return null;
    }
    return current;
  }

  /// First value stored under [key] anywhere in the tree.
  static Object? _deepFind(Object? node, String key) {
    if (node is Map) {
      if (node.containsKey(key)) return node[key];
      for (final value in node.values) {
        final hit = _deepFind(value, key);
        if (hit != null) return hit;
      }
    } else if (node is List) {
      for (final value in node) {
        final hit = _deepFind(value, key);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  /// Every value stored under [key], in document order, not descending into hits.
  static List<Object?> _deepFindAll(Object? node, String key, [List<Object?>? out]) {
    out ??= [];
    if (node is Map) {
      for (final entry in node.entries) {
        if (entry.key == key) {
          out.add(entry.value);
        } else {
          _deepFindAll(entry.value, key, out);
        }
      }
    } else if (node is List) {
      for (final value in node) {
        _deepFindAll(value, key, out);
      }
    }
    return out;
  }

  static Map<String, dynamic>? _asMap(Object? node) => node is Map<String, dynamic> ? node : null;

  static List<Object?> _list(Object? node) => node is List ? node : const [];
}
