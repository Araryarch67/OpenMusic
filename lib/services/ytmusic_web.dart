import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A song row as YouTube Music returns it.
class WebTrack {
  const WebTrack({required this.videoId, required this.title, required this.artist, this.duration, this.artworkUrl});

  final String videoId;
  final String title;
  final String artist;
  final Duration? duration;
  final String? artworkUrl;
}

/// A playlist from the signed-in library.
class WebPlaylist {
  const WebPlaylist({required this.id, required this.title, required this.count, this.thumbnailUrl});

  final String id;
  final String title;
  final int count;
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
  YtMusicWeb({required this.cookies, required this.visitorData, this.authUser = '0'});

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

  final http.Client _http = http.Client();
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
    for (final service in _list(_asMap(response['responseContext'])?['serviceTrackingParams'])
        .whereType<Map<String, dynamic>>()) {
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
        if (playlist != null && playlist.id != 'LM') out.add(playlist);
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

  /// Every song of a playlist (`VL…`) or album (`MPRE…`) page. Album rows carry
  /// neither artist nor artwork; both come from the page header instead.
  Future<List<WebTrack>> browseTracks(String browseId, {int limit = 500}) async {
    final res = await _send('browse', {'browseId': browseId});
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
      artworkUrl: _lastThumb(_at(data, const ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
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
      thumbnailUrl: _lastThumb(_at(data, const ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
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
        artists.addAll([for (final run in runs) if (_isArtistRun(run)) run['text'] as String]);
      }
    }
    title ??= _firstRunText(_list(data['flexColumns']).firstOrNull);
    if (title == null || videoId is! String) return null;
    return WebTrack(
      videoId: videoId,
      title: title.trim(),
      artist: artists.isEmpty ? _looseArtist(data) : artists.join(', '),
      duration:
          _duration(_text(_at(data, const ['fixedColumns', 0, 'musicResponsiveListItemFixedColumnRenderer', 'text']))) ??
          _flexDuration(data),
      artworkUrl: _lastThumb(_at(data, const ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
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
      thumbnailUrl: _lastThumb(_at(data, const ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])),
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
    return _list(_at(response, const ['onResponseReceivedActions', 0, 'appendContinuationItemsAction', 'continuationItems']));
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
