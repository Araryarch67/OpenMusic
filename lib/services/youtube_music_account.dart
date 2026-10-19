import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'youtube_importer.dart';
import 'desktop_login.dart';
import 'ytdlp.dart';
import 'ytmusic_web.dart';

/// Code the user types at google.com/device while we poll for approval.
class DeviceCode {
  const DeviceCode({required this.userCode, required this.verificationUrl, required this.expiresAt});

  final String userCode;
  final String verificationUrl;
  final DateTime expiresAt;
}

class YoutubeMusicLibrary {
  const YoutubeMusicLibrary({required this.liked, required this.playlists, required this.recent});

  final List<Track> liked;
  final List<RemotePlaylist> playlists;
  final List<Track> recent;
}

class RemotePlaylist {
  const RemotePlaylist({
    required this.id,
    required this.title,
    required this.count,
    this.thumbnailUrl,
    this.browseId,
    this.subtitle,
  });

  final String id;
  final String title;
  final int count;
  final String? thumbnailUrl;

  /// Set for public albums / playlists from the discover pages; these load
  /// through YouTube Music's public API whatever the sign-in mode.
  final String? browseId;

  /// Card subtitle as YouTube Music words it ("Album • Artist").
  final String? subtitle;
}

/// A library playlist opened for viewing, with what's needed to edit it.
class RemotePlaylistDetails {
  const RemotePlaylistDetails({required this.tracks, required this.owned, this.privacy, this.rowIds = const {}});

  final List<Track> tracks;

  /// The signed-in account made it, so it can be renamed, edited and deleted.
  final bool owned;
  final PlaylistPrivacy? privacy;

  /// Track id → the row's id in the playlist (needed to remove it).
  final Map<String, String> rowIds;
}

/// A titled row of the discover pages: songs, or albums and playlists.
class RemoteShelf {
  const RemoteShelf({required this.title, this.tracks = const [], this.collections = const []});

  final String title;
  final List<Track> tracks;
  final List<RemotePlaylist> collections;
}

/// Reads the user's YouTube Music library through one of three sessions, in
/// order of preference:
///
/// 1. A browser session (desktop): yt-dlp reuses the login already in the
///    user's browser; nothing is stored here.
/// 2. A web session (mobile): signed in once in the app's own WebView. The
///    requests go to YouTube Music's own API, so history and personalised
///    pages work too.
/// 3. The OAuth device flow with the user's own Google client, against the
///    official YouTube Data API v3. No Google Cloud setup for us, but the
///    official API has no history and no personal mixes.
class YoutubeMusicAccount extends ChangeNotifier {
  static const _scope = 'https://www.googleapis.com/auth/youtube.readonly';
  static const _api = 'https://www.googleapis.com/youtube/v3';
  static const _maxItems = 500;

  final _http = http.Client();

  String? _clientId;
  String? _clientSecret;
  String? _refreshToken;
  String? _accessToken;
  DateTime? _accessExpiry;

  String? accountName;
  String? avatarUrl;

  /// Browser-session mode: yt-dlp reuses the YouTube Music login already in this
  /// browser (desktop). The login itself happens on Google's own site.
  String? _browser;
  String? get browser => _browser;
  bool get usesBrowser => _browser != null;

  /// Web-session mode (mobile): the cookies and visitor data a WebView login
  /// produced, kept in the same private support file as the rest. Requests go
  /// to YouTube Music's own API, so history and personalised pages work too.
  String? _webCookies;
  String? _webVisitor;
  String _webUser = '0';
  YtMusicWeb? _web;
  bool get usesWebSession => _webCookies != null;

  bool connecting = false;

  DeviceCode? pendingCode;
  String? error;
  bool _polling = false;

  bool get hasOAuthClient => (_clientId?.isNotEmpty ?? false) && (_clientSecret?.isNotEmpty ?? false);
  bool get isSignedIn => _browser != null || _webCookies != null || _refreshToken != null;
  bool get isSigningIn => pendingCode != null;
  String? get clientId => _clientId;

  // ── Persistence ─────────────────────────────────────────────────────────

  static Future<File> _file() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'youtube_music_account.json'));

  Future<void> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _clientId = j['clientId'] as String?;
      _clientSecret = j['clientSecret'] as String?;
      _refreshToken = j['refreshToken'] as String?;
      accountName = j['accountName'] as String?;
      avatarUrl = j['avatarUrl'] as String?;
      _browser = j['browser'] as String?;
      _webCookies = j['webCookies'] as String?;
      _webVisitor = j['webVisitor'] as String?;
      _webUser = (j['webUser'] as String?) ?? '0';
      YtDlp.cookiesFromBrowser = _browser;
      notifyListeners();
    } catch (_) {
      // Corrupt file: behave as signed out.
    }
  }

  Future<void> _save() async {
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode({
        'clientId': _clientId,
        'clientSecret': _clientSecret,
        'refreshToken': _refreshToken,
        'accountName': accountName,
        'avatarUrl': avatarUrl,
        'browser': _browser,
        'webCookies': _webCookies,
        'webVisitor': _webVisitor,
        'webUser': _webUser,
      }),
    );
    // Holds a refresh token: keep it readable by this user only.
    if (Platform.isLinux || Platform.isMacOS) await Process.run('chmod', ['600', f.path]);
  }

  Future<void> configure({required String clientId, required String clientSecret}) async {
    _clientId = clientId.trim();
    _clientSecret = clientSecret.trim();
    error = null;
    notifyListeners();
    await _save();
  }

  // ── Browser session ─────────────────────────────────────────────────────

  /// Checks that [browser] is logged in to YouTube Music by reading one liked
  /// song through it, then remembers the browser (never its cookies).
  Future<void> connectBrowser(String browser) async {
    connecting = true;
    error = null;
    notifyListeners();
    final previous = YtDlp.cookiesFromBrowser;
    try {
      YtDlp.cookiesFromBrowser = browser;
      final j = await YtDlp.flatPlaylist(_likedMusicUrl, limit: 1);
      _browser = browser;
      _web?.close();
      _web = null;
      _webCookies = _webVisitor = null;
      _library = null;
      _discover = null;
      accountName = (j['channel'] ?? j['uploader']) as String?;
      if (accountName == 'YouTube Music' || accountName == 'Music') accountName = null;
      await _save();
    } catch (e) {
      YtDlp.cookiesFromBrowser = previous;
      final msg = e is StateError ? e.message : e.toString();
      error = msg.contains('does not exist') || msg.toLowerCase().contains('sign in') || msg.contains('private')
          ? 'Not signed in to YouTube Music in $browser. Log in at music.youtube.com there, then try again.'
          : 'Couldn\'t read the $browser login: $msg';
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  /// Takes over the session a WebView login just produced. The account menu is
  /// checked first, so a half-finished login cannot look connected.
  Future<bool> connectWebSession({
    required String cookies,
    required String visitorData,
    required String authUser,
  }) async {
    connecting = true;
    error = null;
    notifyListeners();
    final web = YtMusicWeb(cookies: cookies, visitorData: visitorData, authUser: authUser);
    try {
      final profile = await web.accountMenu();
      _web?.close();
      _web = web;
      _webCookies = cookies;
      _webVisitor = visitorData;
      _webUser = authUser;
      // One session at a time.
      _browser = null;
      YtDlp.cookiesFromBrowser = null;
      accountName = profile.name ?? accountName;
      avatarUrl = profile.avatarUrl ?? avatarUrl;
      _library = null;
      _discover = null;
      await _save();
      return true;
    } catch (e) {
      web.close();
      error = _describe(e);
      return false;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  /// Signed-out client for the public pages and search; works on every platform.
  final YtMusicWeb _public = YtMusicWeb.anonymous();

  /// Personal pages for a web session, the public ones otherwise.
  YtMusicWeb get _browseClient => usesWebSession ? _webClient : _public;

  Future<List<RemoteShelf>>? _discover;

  /// Home + Explore + Charts shelves; no sign-in needed. Cached until [refresh].
  Future<List<RemoteShelf>> discover({bool refresh = false}) {
    if (refresh || _discover == null) {
      final future = _loadDiscover();
      _discover = future;
      future.then<void>((_) {}, onError: (Object _) => _discover = null);
      if (refresh) notifyListeners();
    }
    return _discover!;
  }

  Future<List<RemoteShelf>> _loadDiscover() async {
    final client = _browseClient;
    // A page that fails (rate limit, layout change) just drops its shelves.
    Future<List<WebShelf>> page(String id) => client.shelves(id).catchError((Object _) => const <WebShelf>[]);
    final pages = await Future.wait([page('FEmusic_home'), page('FEmusic_explore'), page('FEmusic_charts')]);
    final seen = <String>{};
    final out = [
      for (final shelf in pages.expand((p) => p))
        if (seen.add(shelf.title.toLowerCase()))
          RemoteShelf(
            title: shelf.title,
            tracks: _webTracks(shelf.tracks),
            collections: [
              for (final c in shelf.cards)
                RemotePlaylist(
                  id: c.browseId,
                  browseId: c.browseId,
                  title: c.title,
                  subtitle: c.subtitle,
                  count: 0,
                  thumbnailUrl: c.thumbnailUrl,
                ),
            ],
          ),
    ];
    if (out.isEmpty) throw const YtMusicWebError('YouTube Music returned nothing. Check your connection.');
    return out;
  }

  /// Song search on YouTube Music itself (better matches than plain YouTube).
  Future<List<Track>> searchSongs(String query) async => _webTracks(await _browseClient.searchSongs(query));

  /// Google sign-in in an app window: the WebKitGTK helper on Linux, the
  /// in-app WebView page everywhere else.
  static bool get canSignInInWindow => DesktopLogin.supported || !Platform.isLinux;

  /// Linux: runs the sign-in window and takes over its session. False when
  /// the window was closed early or the session didn't work ([error] says why).
  Future<bool> signInWithWindow() async {
    error = null;
    connecting = true;
    notifyListeners();
    try {
      final session = await DesktopLogin.run();
      if (session == null) {
        connecting = false;
        notifyListeners();
        return false;
      }
      return await connectWebSession(
        cookies: session.cookies,
        visitorData: session.visitorData,
        authUser: session.authUser,
      );
    } catch (e) {
      connecting = false;
      error = _describe(e);
      notifyListeners();
      return false;
    }
  }

  YtMusicWeb get _webClient {
    if (_web == null && _webCookies != null) {
      _web = YtMusicWeb(cookies: _webCookies!, visitorData: _webVisitor ?? '', authUser: _webUser);
    }
    return _web!;
  }

  static List<Track> _webTracks(List<WebTrack> tracks) => [
    for (final t in tracks)
      Track.youtube(
        videoId: t.videoId,
        title: t.title,
        artist: t.artist.isEmpty ? Track.unknownArtist : t.artist,
        duration: t.duration,
        artworkUrl: t.artworkUrl,
      ),
  ];

  static const _likedMusicUrl = 'https://music.youtube.com/playlist?list=LM';

  // ── Device flow ─────────────────────────────────────────────────────────

  Future<void> signIn() async {
    if (!hasOAuthClient || _polling) return;
    error = null;
    try {
      final res = await _http.post(
        Uri.parse('https://oauth2.googleapis.com/device/code'),
        body: {'client_id': _clientId!, 'scope': _scope},
      );
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) throw _OAuthError(j['error_description'] as String? ?? j['error'] as String?);
      pendingCode = DeviceCode(
        userCode: j['user_code'] as String,
        verificationUrl: (j['verification_url'] ?? j['verification_uri']) as String,
        expiresAt: DateTime.now().add(Duration(seconds: j['expires_in'] as int)),
      );
      notifyListeners();
      unawaited(_poll(j['device_code'] as String, Duration(seconds: (j['interval'] as int?) ?? 5)));
    } catch (e) {
      error = _describe(e);
      notifyListeners();
    }
  }

  void cancelSignIn() {
    pendingCode = null;
    notifyListeners();
  }

  Future<void> _poll(String deviceCode, Duration interval) async {
    _polling = true;
    try {
      while (pendingCode != null && DateTime.now().isBefore(pendingCode!.expiresAt)) {
        await Future<void>.delayed(interval);
        if (pendingCode == null) return;
        final res = await _http.post(
          Uri.parse('https://oauth2.googleapis.com/token'),
          body: {
            'client_id': _clientId!,
            'client_secret': _clientSecret!,
            'device_code': deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          },
        );
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        switch (j['error']) {
          case null:
            _takeTokens(j);
            pendingCode = null;
            await _loadProfile();
            await _save();
            notifyListeners();
            return;
          case 'authorization_pending':
            continue;
          case 'slow_down':
            interval += const Duration(seconds: 5);
          case 'access_denied':
            throw const _OAuthError('Sign-in was cancelled on the Google page.');
          default:
            throw _OAuthError(j['error_description'] as String? ?? j['error'] as String);
        }
      }
      if (pendingCode != null) throw const _OAuthError('The code expired. Try signing in again.');
    } catch (e) {
      error = _describe(e);
      pendingCode = null;
      notifyListeners();
    } finally {
      _polling = false;
    }
  }

  void _takeTokens(Map<String, dynamic> j) {
    _accessToken = j['access_token'] as String;
    _accessExpiry = DateTime.now().add(Duration(seconds: (j['expires_in'] as int) - 60));
    _refreshToken = (j['refresh_token'] as String?) ?? _refreshToken;
  }

  Future<String> _token() async {
    if (_accessToken != null && DateTime.now().isBefore(_accessExpiry!)) return _accessToken!;
    if (_refreshToken == null) throw const _OAuthError('Not signed in.');
    final res = await _http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'client_id': _clientId!,
        'client_secret': _clientSecret!,
        'refresh_token': _refreshToken!,
        'grant_type': 'refresh_token',
      },
    );
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      if (j['error'] == 'invalid_grant') await signOut(revoke: false); // revoked elsewhere
      throw _OAuthError(j['error_description'] as String? ?? 'Session expired. Sign in again.');
    }
    _takeTokens(j);
    return _accessToken!;
  }

  Future<void> signOut({bool revoke = true}) async {
    final token = _refreshToken;
    final hadWebSession = _webCookies != null;
    _refreshToken = _accessToken = null;
    accountName = avatarUrl = null;
    _browser = null;
    YtDlp.cookiesFromBrowser = null;
    _web?.close();
    _web = null;
    _webCookies = _webVisitor = null;
    _webUser = '0';
    _library = null;
    _discover = null;
    notifyListeners();
    await _save();
    if (hadWebSession) unawaited(_clearWebViewCookies());
    if (revoke && token != null) {
      unawaited(_http.post(Uri.parse('https://oauth2.googleapis.com/revoke'), body: {'token': token}));
    }
  }

  /// Disconnect should disconnect the login WebView as well. On platforms
  /// without the WebView plugin this is a no-op.
  static Future<void> _clearWebViewCookies() async {
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {
      // The plugin is absent on platforms without a WebView.
    }
  }

  // ── YouTube Data API v3 ─────────────────────────────────────────────────

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query) async {
    final res = await _http.get(
      Uri.parse('$_api/$path').replace(queryParameters: query),
      headers: {'Authorization': 'Bearer ${await _token()}'},
    );
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      final message = (j['error'] as Map<String, dynamic>?)?['message'] as String?;
      throw _OAuthError(message ?? 'YouTube API error ${res.statusCode}');
    }
    return j;
  }

  /// Follows `nextPageToken` until [_maxItems].
  Future<List<Map<String, dynamic>>> _paged(String path, Map<String, String> query) async {
    final items = <Map<String, dynamic>>[];
    String? page;
    do {
      final j = await _get(path, {...query, 'maxResults': '50', 'pageToken': ?page});
      items.addAll((j['items'] as List).cast<Map<String, dynamic>>());
      page = j['nextPageToken'] as String?;
    } while (page != null && items.length < _maxItems);
    return items;
  }

  Future<void> _loadProfile() async {
    try {
      final j = await _get('channels', {'part': 'snippet', 'mine': 'true'});
      final snippet = ((j['items'] as List).firstOrNull as Map<String, dynamic>?)?['snippet'] as Map<String, dynamic>?;
      accountName = snippet?['title'] as String?;
      avatarUrl =
          ((snippet?['thumbnails'] as Map<String, dynamic>?)?['default'] as Map<String, dynamic>?)?['url'] as String?;
    } catch (_) {
      // Profile is cosmetic.
    }
  }

  // ── Library (cached; shared by the sidebar and pages) ───────────────────

  Future<YoutubeMusicLibrary>? _library;

  /// Liked music, playlists and recent history; loaded once until [refresh].
  Future<YoutubeMusicLibrary> library({bool refresh = false}) {
    if (refresh || _library == null) {
      final future = _loadLibrary();
      _library = future;
      future.then<void>((_) {}, onError: (Object _) => _library = null);
      if (refresh) notifyListeners();
    }
    return _library!;
  }

  Future<YoutubeMusicLibrary> _loadLibrary() async {
    final (liked, lists, recent) = await (likedMusic(), playlists(), history()).wait;
    _likedIds
      ..clear()
      ..addAll(liked.map((t) => t.id));
    return YoutubeMusicLibrary(liked: liked, playlists: lists, recent: recent);
  }

  // ── Editing the library (signed in through Google's page) ───────────────

  /// Likes and playlist edits go through YouTube Music's own API, so they show
  /// up in the YouTube Music apps too.
  bool get canEdit => usesWebSession;

  final Set<String> _likedIds = {};
  bool isLiked(Track t) => _likedIds.contains(t.id);

  Future<T> _editing<T>(Future<T> Function(YtMusicWeb web) change) async {
    if (!canEdit) throw const YtMusicWebError('Sign in with Google to change your YouTube Music library.');
    try {
      return await change(_webClient);
    } catch (e) {
      throw YtMusicWebError(_describe(e));
    }
  }

  /// Puts a song in (or takes it out of) "Liked music". Shown right away;
  /// undone if YouTube Music refuses.
  Future<void> setLiked(Track t, bool liked) async {
    liked ? _likedIds.add(t.id) : _likedIds.remove(t.id);
    notifyListeners();
    try {
      await _editing((web) => web.rate(t.videoId!, liked: liked));
      library(refresh: true).ignore();
    } catch (_) {
      liked ? _likedIds.remove(t.id) : _likedIds.add(t.id);
      notifyListeners();
      rethrow;
    }
  }

  Future<RemotePlaylistDetails> playlistDetails(String playlistId) async {
    if (!usesWebSession) return RemotePlaylistDetails(tracks: await playlistTracks(playlistId), owned: false);
    final page = await _webClient.playlistPage(playlistId, limit: _maxItems);
    final tracks = _webTracks(page.tracks);
    return RemotePlaylistDetails(
      tracks: tracks,
      owned: page.owned,
      privacy: page.privacy,
      rowIds: {
        for (var i = 0; i < page.tracks.length; i++)
          tracks[i].id: ?page.tracks[i].setVideoId,
      },
    );
  }

  /// Creates a playlist (optionally with songs) and returns its id.
  Future<String> createPlaylist(
    String title, {
    PlaylistPrivacy privacy = PlaylistPrivacy.private,
    List<Track> tracks = const [],
  }) async {
    final id = await _editing(
      (web) => web.createPlaylist(title, privacy: privacy, videoIds: [for (final t in tracks) ?t.videoId]),
    );
    library(refresh: true).ignore();
    return id;
  }

  Future<void> renamePlaylist(String id, String title) async {
    await _editing((web) => web.renamePlaylist(id, title));
    library(refresh: true).ignore();
  }

  Future<void> setPlaylistPrivacy(String id, PlaylistPrivacy privacy) =>
      _editing((web) => web.setPlaylistPrivacy(id, privacy));

  Future<void> deletePlaylist(String id) async {
    await _editing((web) => web.deletePlaylist(id));
    library(refresh: true).ignore();
  }

  Future<void> addToPlaylist(String id, List<Track> tracks) async {
    await _editing((web) => web.addToPlaylist(id, [for (final t in tracks) ?t.videoId]));
    library(refresh: true).ignore();
  }

  Future<void> removeFromPlaylist(String id, Track t, String rowId) async {
    await _editing((web) => web.removeFromPlaylist(id, [(videoId: t.videoId!, setVideoId: rowId)]));
    library(refresh: true).ignore();
  }

  Future<void> movePlaylistItem(String id, String rowId, String? beforeRowId) =>
      _editing((web) => web.movePlaylistItem(id, rowId, beforeRowId));

  /// Recently played. Browser and web sessions have it; the Data API does not.
  Future<List<Track>> history() async {
    if (usesWebSession) {
      try {
        return _webTracks(await _webClient.history());
      } catch (_) {
        return const [];
      }
    }
    if (!usesBrowser) return const [];
    try {
      return _flatTracks(await YtDlp.flatPlaylist(':ythis', limit: 30));
    } catch (_) {
      return const [];
    }
  }

  static List<Track> _flatTracks(Map<String, dynamic> j) => [
    for (final e in ((j['entries'] as List?) ?? const []).cast<Map<String, dynamic>>())
      if (e['id'] is String &&
          e['title'] is String &&
          e['title'] != '[Private video]' &&
          e['title'] != '[Deleted video]')
        () {
          final names = YoutubeImporter.parseTitle(
            e['title'] as String,
            (e['channel'] ?? e['uploader'] ?? '') as String,
          );
          final thumbs = (e['thumbnails'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
          return Track.youtube(
            videoId: e['id'] as String,
            title: names.title,
            artist: names.artist,
            duration: e['duration'] is num ? Duration(seconds: (e['duration'] as num).round()) : null,
            artworkUrl: thumbs.isEmpty ? null : (thumbs.last['url'] as String?)?.split('?').first,
          );
        }(),
  ];

  Future<List<RemotePlaylist>> playlists() async {
    if (usesWebSession) {
      final lists = await _webClient.libraryPlaylists();
      return [
        for (final p in lists)
          RemotePlaylist(id: p.id, title: p.title, count: p.count, thumbnailUrl: p.thumbnailUrl),
      ];
    }
    if (usesBrowser) {
      final j = await YtDlp.flatPlaylist('https://www.youtube.com/feed/playlists');
      return [
        for (final e in ((j['entries'] as List?) ?? const []).cast<Map<String, dynamic>>())
          if (e['id'] is String && e['id'] != 'LM' && e['id'] != 'LL')
            RemotePlaylist(
              id: e['id'] as String,
              title: (e['title'] as String?) ?? 'Playlist',
              count: (e['playlist_count'] as int?) ?? 0,
              thumbnailUrl: ((e['thumbnails'] as List?)?.lastOrNull as Map<String, dynamic>?)?['url'] as String?,
            ),
      ];
    }
    final items = await _paged('playlists', {'part': 'snippet,contentDetails', 'mine': 'true'});
    return [
      for (final i in items)
        RemotePlaylist(
          id: i['id'] as String,
          title: (i['snippet'] as Map<String, dynamic>)['title'] as String,
          count: ((i['contentDetails'] as Map<String, dynamic>)['itemCount'] as int?) ?? 0,
          thumbnailUrl: _thumb(i['snippet'] as Map<String, dynamic>),
        ),
    ];
  }

  /// Liked videos in the Music category: what YouTube Music shows as "Liked music".
  Future<List<Track>> likedMusic() async {
    if (usesWebSession) return _webTracks(await _webClient.playlistTracks('LM', limit: _maxItems));
    if (usesBrowser) return _flatTracks(await YtDlp.flatPlaylist(_likedMusicUrl));
    final items = await _paged('videos', {'part': 'snippet,contentDetails', 'myRating': 'like'});
    return [
      for (final i in items)
        if ((i['snippet'] as Map<String, dynamic>)['categoryId'] == '10') _videoToTrack(i),
    ];
  }

  /// Songs YouTube Music would play after [seed] (its radio), without the seed itself.
  Future<List<Track>> upNext(Track seed) async {
    final rows = await _browseClient.radio(seed.videoId!);
    return _webTracks(rows.where((r) => r.videoId != seed.videoId).toList());
  }

  /// Songs of a playlist from the library or of a public album / playlist.
  Future<List<Track>> collectionTracks(RemotePlaylist p) async {
    if (p.browseId != null) return _webTracks(await _browseClient.browseTracks(p.browseId!, limit: _maxItems));
    return playlistTracks(p.id);
  }

  Future<List<Track>> playlistTracks(String playlistId) async {
    if (usesWebSession) {
      return _webTracks(await _webClient.playlistTracks(playlistId, limit: _maxItems));
    }
    if (usesBrowser) {
      return _flatTracks(await YtDlp.flatPlaylist('https://music.youtube.com/playlist?list=$playlistId'));
    }
    final items = await _paged('playlistItems', {'part': 'snippet,contentDetails', 'playlistId': playlistId});
    return [for (final i in items) ?_playlistItemToTrack(i)];
  }

  Track _videoToTrack(Map<String, dynamic> i) {
    final s = i['snippet'] as Map<String, dynamic>;
    final names = YoutubeImporter.parseTitle(s['title'] as String, s['channelTitle'] as String? ?? '');
    return Track.youtube(
      videoId: i['id'] as String,
      title: names.title,
      artist: names.artist,
      duration: _isoDuration((i['contentDetails'] as Map<String, dynamic>?)?['duration'] as String?),
      artworkUrl: _thumb(s),
    );
  }

  Track? _playlistItemToTrack(Map<String, dynamic> i) {
    final s = i['snippet'] as Map<String, dynamic>;
    final videoId = ((s['resourceId'] as Map<String, dynamic>?)?['videoId']) as String?;
    final title = s['title'] as String?;
    // Deleted / private entries have no owner and a placeholder title.
    if (videoId == null || title == null || s['videoOwnerChannelTitle'] == null) return null;
    final names = YoutubeImporter.parseTitle(title, s['videoOwnerChannelTitle'] as String);
    return Track.youtube(videoId: videoId, title: names.title, artist: names.artist, artworkUrl: _thumb(s));
  }

  static String? _thumb(Map<String, dynamic> snippet) {
    final t = snippet['thumbnails'] as Map<String, dynamic>?;
    if (t == null) return null;
    for (final k in ['maxres', 'standard', 'high', 'medium', 'default']) {
      final url = (t[k] as Map<String, dynamic>?)?['url'] as String?;
      if (url != null) return url;
    }
    return null;
  }

  /// Parses ISO-8601 durations like "PT3M42S".
  static Duration? _isoDuration(String? iso) {
    final m = RegExp(r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$').firstMatch(iso ?? '');
    if (m == null) return null;
    int n(int g) => int.tryParse(m.group(g) ?? '') ?? 0;
    return Duration(hours: n(1), minutes: n(2), seconds: n(3));
  }

  static String _describe(Object e) => switch (e) {
    _OAuthError(:final message) => message ?? 'Sign-in failed.',
    YtMusicWebError(:final message) => message,
    TimeoutException() => 'The request timed out. Try again.',
    SocketException() || http.ClientException() => 'Network error. Check your connection.',
    _ => e.toString(),
  };

  @override
  void dispose() {
    pendingCode = null;
    _http.close();
    _web?.close();
    _public.close();
    super.dispose();
  }
}

class _OAuthError implements Exception {
  const _OAuthError(this.message);
  final String? message;

  @override
  String toString() => message ?? 'OAuth error';
}
