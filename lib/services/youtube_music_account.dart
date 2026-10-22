import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'desktop_login.dart';
import 'ytmusic_web.dart';

class YoutubeMusicLibrary {
  const YoutubeMusicLibrary({
    required this.liked,
    required this.playlists,
    required this.recent,
    this.artists = const [],
  });

  final List<Track> liked;
  final List<RemotePlaylist> playlists;
  final List<Track> recent;

  /// Artists the account follows; each opens as its songs ([RemotePlaylist.browseId]).
  final List<RemotePlaylist> artists;

  YoutubeMusicLibrary copyWith({List<Track>? liked, List<RemotePlaylist>? playlists, List<RemotePlaylist>? artists}) =>
      YoutubeMusicLibrary(
        liked: liked ?? this.liked,
        playlists: playlists ?? this.playlists,
        recent: recent,
        artists: artists ?? this.artists,
      );
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

  RemotePlaylist copyWith({String? title, int? count, String? thumbnailUrl}) => RemotePlaylist(
    id: id,
    title: title ?? this.title,
    count: count ?? this.count,
    thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
    browseId: browseId,
    subtitle: subtitle,
  );

  factory RemotePlaylist.fromJson(Map<String, dynamic> j) => RemotePlaylist(
    id: j['id'] as String,
    title: j['title'] as String,
    count: j['count'] as int? ?? 0,
    thumbnailUrl: j['thumb'] as String?,
    browseId: j['browseId'] as String?,
    subtitle: j['subtitle'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'count': count,
    'thumb': thumbnailUrl,
    'browseId': browseId,
    'subtitle': subtitle,
  };
}

/// A library playlist opened for viewing, with what's needed to edit it.
class RemotePlaylistDetails {
  const RemotePlaylistDetails({
    required this.tracks,
    required this.owned,
    this.collaborative = false,
    this.privacy,
    this.rowIds = const {},
  });

  final List<Track> tracks;

  /// The signed-in account made it, so it can be renamed, edited and deleted.
  final bool owned;

  /// Shared with friends who add songs too; anyone in it can remove songs.
  final bool collaborative;
  final PlaylistPrivacy? privacy;

  /// Track id → the row's id in the playlist (needed to remove it).
  final Map<String, String> rowIds;

  RemotePlaylistDetails copyWith({
    List<Track>? tracks,
    bool? collaborative,
    PlaylistPrivacy? privacy,
    Map<String, String>? rowIds,
  }) => RemotePlaylistDetails(
    tracks: tracks ?? this.tracks,
    owned: owned,
    collaborative: collaborative ?? this.collaborative,
    privacy: privacy ?? this.privacy,
    rowIds: rowIds ?? this.rowIds,
  );
}

/// A titled row of the discover pages: songs, or albums and playlists.
class RemoteShelf {
  const RemoteShelf({required this.title, this.tracks = const [], this.collections = const []});

  factory RemoteShelf.fromJson(Map<String, dynamic> j) => RemoteShelf(
    title: j['title'] as String,
    tracks: [for (final t in j['tracks'] as List) Track.fromJson((t as Map).cast())],
    collections: [for (final c in j['collections'] as List) RemotePlaylist.fromJson((c as Map).cast())],
  );

  final String title;
  final List<Track> tracks;
  final List<RemotePlaylist> collections;

  Map<String, dynamic> toJson() => {
    'title': title,
    'tracks': [for (final t in tracks) t.toJson()],
    'collections': [for (final c in collections) c.toJson()],
  };
}

/// A search hit: a song to play ([track]) or an artist / album / playlist to open ([collection]).
class SearchHit {
  const SearchHit({required this.kind, required this.title, required this.subtitle, this.track, this.collection});

  final WebResultKind kind;
  final String title;
  final String subtitle;
  final Track? track;
  final RemotePlaylist? collection;

  /// Cover for the row / card.
  Track get cover =>
      track ??
      Track.youtube(videoId: 'cover-${collection!.id}', title: title, artist: '', artworkUrl: collection!.thumbnailUrl);
}

/// YouTube Music's "All" search, in app terms.
class SearchResults {
  const SearchResults({
    this.top,
    this.songs = const [],
    this.artists = const [],
    this.albums = const [],
    this.playlists = const [],
  });

  final SearchHit? top;
  final List<Track> songs;
  final List<RemotePlaylist> artists;
  final List<RemotePlaylist> albums;
  final List<RemotePlaylist> playlists;
}

/// The YouTube Music account: signed in once on Google's own page (a window
/// on Linux, the app's WebView elsewhere), whose session then talks to
/// YouTube Music's own API, so likes, playlists, history and personal pages
/// all work. Signed out, the public pages and search still do.
class YoutubeMusicAccount extends ChangeNotifier {
  static const _maxItems = 500;

  String? accountName;
  String? avatarUrl;

  /// The cookies and visitor data the sign-in page produced, kept in the
  /// app's private support file.
  String? _webCookies;
  String? _webVisitor;
  String _webUser = '0';
  YtMusicWeb? _web;

  bool connecting = false;
  String? error;

  bool get isSignedIn => _webCookies != null;

  // ── Persistence ─────────────────────────────────────────────────────────

  static Future<File> _file() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'youtube_music_account.json'));

  Future<void> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _webCookies = j['webCookies'] as String?;
      if (_webCookies == null) return; // never signed in, or with a sign-in the app no longer has
      _webVisitor = j['webVisitor'] as String?;
      _webUser = (j['webUser'] as String?) ?? '0';
      accountName = j['accountName'] as String?;
      avatarUrl = j['avatarUrl'] as String?;
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
        'accountName': accountName,
        'avatarUrl': avatarUrl,
        'webCookies': _webCookies,
        'webVisitor': _webVisitor,
        'webUser': _webUser,
      }),
    );
    // Holds the session's cookies: keep it readable by this user only.
    if (Platform.isLinux || Platform.isMacOS) await Process.run('chmod', ['600', f.path]);
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
      accountName = profile.name ?? accountName;
      avatarUrl = profile.avatarUrl ?? avatarUrl;
      _forgetLibrary();
      _discover = _discovered = null; // another account's shelves
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

  /// Personal pages when signed in, the public ones otherwise.
  YtMusicWeb get _browseClient => isSignedIn ? _webClient : _public;

  Future<List<RemoteShelf>>? _discover;

  /// The shelves to show right now: last session's from disk until today's
  /// arrive, so Home paints at once on launch. Null before the first load.
  List<RemoteShelf>? get discovered => _discovered;
  List<RemoteShelf>? _discovered;

  /// Home + Explore + Charts shelves; no sign-in needed. Cached until [refresh].
  Future<List<RemoteShelf>> discover({bool refresh = false}) {
    if (refresh || _discover == null) {
      final first = _discover == null && !refresh;
      final future = _loadDiscover().then((shelves) {
        _discovered = shelves;
        _saveDiscover(shelves).ignore();
        notifyListeners();
        return shelves;
      });
      _discover = future;
      future.then<void>((_) {}, onError: (Object _) => _discover = null);
      if (first) {
        // Meanwhile, what the last session showed (same account, under a week old).
        _cachedDiscover().then((cached) {
          if (cached == null || _discovered != null) return;
          _discovered = cached;
          notifyListeners();
        }).ignore();
      }
      if (refresh) notifyListeners();
    }
    return _discover!;
  }

  String get _discoverOwner => accountName ?? '';

  static Future<File> _discoverFile() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'discover-cache.json'));

  Future<List<RemoteShelf>?> _cachedDiscover() async {
    try {
      final f = await _discoverFile();
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch(j['at'] as int);
      if (j['owner'] != _discoverOwner || DateTime.now().difference(at) > const Duration(days: 7)) return null;
      return [for (final s in j['shelves'] as List) RemoteShelf.fromJson((s as Map).cast())];
    } catch (_) {
      return null; // unreadable or no app folder (tests): just wait for the network
    }
  }

  Future<void> _saveDiscover(List<RemoteShelf> shelves) async {
    try {
      final f = await _discoverFile();
      await f.parent.create(recursive: true);
      final part = File('${f.path}.part');
      await part.writeAsString(
        jsonEncode({
          'owner': _discoverOwner,
          'at': DateTime.now().millisecondsSinceEpoch,
          'shelves': [for (final s in shelves) s.toJson()],
        }),
      );
      await part.rename(f.path);
    } catch (_) {}
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

  /// Music videos on YouTube Music, for songs its Songs search doesn't have.
  Future<List<Track>> searchVideos(String query) async => _webTracks(await _browseClient.searchVideos(query));

  /// Everything matching [query] (top result, songs, artists, albums, playlists).
  Future<SearchResults> search(String query) async {
    final r = await _browseClient.search(query);
    return SearchResults(
      top: r.top == null ? null : hitOf(r.top!),
      songs: _webTracks(r.songs),
      artists: [for (final a in r.artists) _collectionOf(a)],
      albums: [for (final a in r.albums) _collectionOf(a)],
      playlists: [for (final a in r.playlists) _collectionOf(a)],
    );
  }

  /// Only artists, albums or playlists matching [query].
  Future<List<RemotePlaylist>> searchOnly(String query, WebResultKind kind) async => [
    for (final r in await _browseClient.searchOnly(query, kind)) _collectionOf(r),
  ];

  /// Completions and direct hits for the search box.
  Future<({List<String> queries, List<SearchHit> hits})> suggestions(String input) async {
    final s = await _browseClient.suggestions(input);
    return (queries: s.queries, hits: [for (final i in s.items) hitOf(i)]);
  }

  static SearchHit hitOf(WebResult r) => SearchHit(
    kind: r.kind,
    title: r.title,
    subtitle: r.subtitle,
    track: r.track == null ? null : _webTracks([r.track!]).single,
    collection: r.track == null ? _collectionOf(r) : null,
  );

  static RemotePlaylist _collectionOf(WebResult r) => RemotePlaylist(
    id: r.browseId!,
    browseId: r.browseId,
    title: r.title,
    count: 0,
    subtitle: r.subtitle,
    thumbnailUrl: r.thumbnailUrl,
  );

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
        artistId: t.artistId,
      ),
  ];

  Future<void> signOut() async {
    final hadSession = _webCookies != null;
    accountName = avatarUrl = null;
    _web?.close();
    _web = null;
    _webCookies = _webVisitor = null;
    _webUser = '0';
    _forgetLibrary();
    _discover = _discovered = null; // another account's shelves
    notifyListeners();
    await _save();
    if (hadSession) unawaited(_clearWebViewCookies());
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

  // ── Library (cached; shared by the sidebar and pages) ───────────────────

  Future<YoutubeMusicLibrary>? _library;

  /// The library as last loaded, with every edit since applied to it: edits
  /// show the moment they're made instead of after a reload.
  YoutubeMusicLibrary? _libraryNow;

  /// Bumped by every edit, so a load that started before one can tell its
  /// copy is out of date.
  int _edits = 0;

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
    final edits = _edits;
    final (liked, lists, recent, artists) = await (likedMusic(), playlists(), history(), followedArtists()).wait;
    // Edited while loading: YouTube Music may not have had the edit yet when
    // it answered, so keep what's shown and look again once edits settle.
    final now = _libraryNow;
    if (edits != _edits) {
      Timer(const Duration(seconds: 3), () => library(refresh: true).ignore());
      if (now != null) return now;
    }
    _likedIds
      ..clear()
      ..addAll(liked.map((t) => t.id));
    _followedIds
      ..clear()
      ..addAll(artists.map((a) => a.id));
    final l = _libraryNow = YoutubeMusicLibrary(liked: liked, playlists: lists, recent: recent, artists: artists);
    notifyListeners();
    return l;
  }

  /// Liked music as shown now, likes since the last load included.
  List<Track>? get likedNow => _libraryNow?.liked;

  void _forgetLibrary() {
    _library = null;
    _libraryNow = null;
    _details.clear();
  }

  /// Applies an edit to the library on screen right away. [edit] is false
  /// for news from YouTube Music itself, which a load needn't wait out.
  void _patchLibrary(YoutubeMusicLibrary Function(YoutubeMusicLibrary l) change, {bool edit = true}) {
    if (edit) _edits++;
    final now = _libraryNow;
    if (now == null) return;
    final next = _libraryNow = change(now);
    _library = Future.value(next);
    notifyListeners();
  }

  void _patchPlaylist(String id, RemotePlaylist Function(RemotePlaylist p) change, {bool edit = true}) => _patchLibrary(
    (l) => l.copyWith(playlists: [for (final p in l.playlists) p.id == id ? change(p) : p]),
    edit: edit,
  );

  /// Playlists opened before, as last seen (edits included): they open at
  /// once and are brought up to date behind the scenes.
  final _details = <String, RemotePlaylistDetails>{};

  RemotePlaylistDetails? cachedPlaylist(String id) => _details[id];

  void _patchDetails(String id, RemotePlaylistDetails Function(RemotePlaylistDetails d) change) {
    _edits++;
    final d = _details[id];
    if (d == null) return;
    _details[id] = change(d);
    notifyListeners();
  }

  /// Followed artists. Only YouTube Music's own API (the in-app sign-in) lists them.
  Future<List<RemotePlaylist>> followedArtists() async {
    if (!isSignedIn) return const [];
    try {
      return [
        for (final a in await _webClient.followedArtists())
          RemotePlaylist(
            id: a.browseId,
            browseId: a.browseId,
            title: a.name,
            count: 0,
            subtitle: a.subtitle ?? 'Artist',
            thumbnailUrl: a.thumbnailUrl,
          ),
      ];
    } catch (e) {
      // The rest of the library is still worth showing.
      debugPrint('Followed artists failed: $e');
      return const [];
    }
  }

  // ── Editing the library (signed in through Google's page) ───────────────

  /// Likes and playlist edits go through YouTube Music's own API, so they show
  /// up in the YouTube Music apps too.
  bool get canEdit => isSignedIn;

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
    final before = _libraryNow?.liked;
    _patchLibrary(
      (l) => l.copyWith(
        liked: [
          if (liked) t,
          for (final x in l.liked)
            if (x.id != t.id) x,
        ],
      ),
    );
    try {
      await _editing((web) => web.rate(t.videoId!, liked: liked));
    } catch (_) {
      liked ? _likedIds.remove(t.id) : _likedIds.add(t.id);
      if (before != null) _patchLibrary((l) => l.copyWith(liked: before));
      notifyListeners();
      rethrow;
    }
  }

  final Set<String> _followedIds = {};
  bool isFollowing(String artistId) => _followedIds.contains(artistId);

  /// Follows or unfollows an artist in YouTube Music. Shown right away;
  /// undone if YouTube Music refuses.
  Future<void> setFollowing(String artistId, bool following) async {
    following ? _followedIds.add(artistId) : _followedIds.remove(artistId);
    if (!following) {
      _patchLibrary(
        (l) => l.copyWith(
          artists: [
            for (final a in l.artists)
              if (a.id != artistId) a,
          ],
        ),
      );
    }
    notifyListeners();
    try {
      await _editing((web) => web.setFollowing(artistId, following: following));
      // A new artist's name and picture come from YouTube Music's list.
      if (following) {
        final artists = await followedArtists();
        if (artists.any((a) => a.id == artistId)) _patchLibrary((l) => l.copyWith(artists: artists));
      }
    } catch (_) {
      following ? _followedIds.remove(artistId) : _followedIds.add(artistId);
      notifyListeners();
      rethrow;
    }
  }

  /// A library playlist as YouTube Music has it now; [cachedPlaylist] shows
  /// it until then. Notifies when it differs from what was shown.
  Future<RemotePlaylistDetails> playlistDetails(String playlistId) async {
    final edits = _edits;
    final RemotePlaylistDetails d;
    if (isSignedIn) {
      final page = await _webClient.playlistPage(playlistId, limit: _maxItems);
      final tracks = _webTracks(page.tracks);
      d = RemotePlaylistDetails(
        tracks: tracks,
        owned: page.owned,
        collaborative: page.collaborative,
        privacy: page.privacy,
        rowIds: {for (var i = 0; i < page.tracks.length; i++) tracks[i].id: ?page.tracks[i].setVideoId},
      );
    } else {
      d = RemotePlaylistDetails(tracks: await playlistTracks(playlistId), owned: false);
    }
    // Edited meanwhile: the copy with the edit is newer than this answer.
    final shown = _details[playlistId];
    if (edits != _edits && shown != null) return shown;
    _details[playlistId] = d;
    if (shown != null && !_sameDetails(shown, d)) notifyListeners();
    // The library's song count and cover follow the playlist.
    final listed = _libraryNow?.playlists.where((p) => p.id == playlistId).firstOrNull;
    if (listed != null && listed.count != d.tracks.length) {
      _patchPlaylist(playlistId, (p) => p.copyWith(count: d.tracks.length), edit: false);
    }
    return d;
  }

  static bool _sameDetails(RemotePlaylistDetails a, RemotePlaylistDetails b) =>
      a.owned == b.owned &&
      a.collaborative == b.collaborative &&
      a.privacy == b.privacy &&
      listEquals([for (final t in a.tracks) t.id], [for (final t in b.tracks) t.id]) &&
      mapEquals(a.rowIds, b.rowIds);

  /// Creates a playlist (optionally with songs) and returns its id.
  Future<String> createPlaylist(
    String title, {
    PlaylistPrivacy privacy = PlaylistPrivacy.private,
    List<Track> tracks = const [],
  }) async {
    final id = await _editing(
      (web) => web.createPlaylist(title, privacy: privacy, videoIds: [for (final t in tracks) ?t.videoId]),
    );
    final playlist = RemotePlaylist(
      id: id,
      title: title,
      count: tracks.length,
      thumbnailUrl: tracks.firstOrNull?.artworkUrl,
    );
    _patchLibrary((l) => l.copyWith(playlists: [playlist, ...l.playlists]));
    // Its rows' ids come with the first look at it.
    _details[id] = RemotePlaylistDetails(tracks: tracks, owned: true, privacy: privacy);
    return id;
  }

  Future<void> renamePlaylist(String id, String title) async {
    await _editing((web) => web.renamePlaylist(id, title));
    _patchPlaylist(id, (p) => p.copyWith(title: title));
  }

  Future<void> setPlaylistPrivacy(String id, PlaylistPrivacy privacy) async {
    await _editing((web) => web.setPlaylistPrivacy(id, privacy));
    _patchDetails(id, (d) => d.copyWith(privacy: privacy));
  }

  Future<void> deletePlaylist(String id) async {
    await _editing((web) => web.deletePlaylist(id));
    _details.remove(id);
    _patchLibrary(
      (l) => l.copyWith(
        playlists: [
          for (final p in l.playlists)
            if (p.id != id) p,
        ],
      ),
    );
  }

  /// Adds songs to a playlist; they show in it (and in its count) as soon as
  /// YouTube Music takes them, no reload. Songs already in it are skipped.
  /// Returns how many were added.
  Future<int> addToPlaylist(String id, List<Track> tracks) async {
    final rows = await _editing((web) => web.addToPlaylist(id, [for (final t in tracks) ?t.videoId]));
    final rowOf = {for (final r in rows) r.videoId: r.setVideoId};
    final shown = _details[id];
    // The reply names the rows it made; without that, anything not shown yet.
    final have = {...?shown?.tracks.map((t) => t.id)};
    final added = [
      for (final t in tracks)
        if (rows.isEmpty ? have.add(t.id) : rowOf.containsKey(t.videoId)) t,
    ];
    if (added.isEmpty) return 0;
    _patchDetails(
      id,
      (d) => d.copyWith(
        tracks: [...d.tracks, ...added],
        rowIds: {...d.rowIds, for (final t in added) t.id: ?rowOf[t.videoId]},
      ),
    );
    _patchPlaylist(
      id,
      (p) => p.copyWith(count: p.count + added.length, thumbnailUrl: p.thumbnailUrl ?? added.first.artworkUrl),
    );
    return added.length;
  }

  Future<void> removeFromPlaylist(String id, Track t, String rowId) async {
    await _editing((web) => web.removeFromPlaylist(id, [(videoId: t.videoId!, setVideoId: rowId)]));
    _patchDetails(
      id,
      (d) => d.copyWith(
        tracks: [
          for (final x in d.tracks)
            if (x.id != t.id) x,
        ],
        rowIds: {...d.rowIds}..remove(t.id),
      ),
    );
    _patchPlaylist(id, (p) => p.copyWith(count: p.count > 0 ? p.count - 1 : 0));
  }

  Future<void> movePlaylistItem(String id, String rowId, String? beforeRowId) =>
      _editing((web) => web.movePlaylistItem(id, rowId, beforeRowId));

  /// The link that lets friends add songs to the playlist. A private playlist
  /// is made unlisted first: YouTube Music keeps collaborators out of private ones.
  Future<String> inviteLink(String id, {required PlaylistPrivacy? privacy}) async {
    final link = await _editing((web) async {
      if (privacy == PlaylistPrivacy.private) await web.setPlaylistPrivacy(id, PlaylistPrivacy.unlisted);
      return web.collaborationLink(id);
    });
    _patchDetails(
      id,
      (d) => d.copyWith(
        collaborative: true,
        privacy: privacy == PlaylistPrivacy.private ? PlaylistPrivacy.unlisted : null,
      ),
    );
    return link;
  }

  Future<void> stopCollaboration(String id) async {
    await _editing((web) => web.stopCollaboration(id));
    _patchDetails(id, (d) => d.copyWith(collaborative: false));
  }

  /// Joins a friend's playlist from their invite link and returns its id.
  Future<String> joinPlaylist(String inviteLink) async {
    final invite = YtMusicWeb.parseInvite(inviteLink);
    if (invite == null) throw const YtMusicWebError('That isn\'t a YouTube Music invite link.');
    // Joining twice is refused like a bad session; already in, just open it.
    final mine = await library().then((l) => l.playlists, onError: (Object _) => const <RemotePlaylist>[]);
    if (mine.any((p) => p.id == invite.playlistId)) return invite.playlistId;
    await _editing((web) => web.joinCollaboration(invite.playlistId, invite.token));
    // Its name and cover come from YouTube Music's list.
    try {
      final lists = await playlists();
      _patchLibrary((l) => l.copyWith(playlists: lists));
    } catch (_) {
      library(refresh: true).ignore();
    }
    return invite.playlistId;
  }

  /// Recently played.
  Future<List<Track>> history() async {
    if (!isSignedIn) return const [];
    try {
      return _webTracks(await _webClient.history());
    } catch (_) {
      return const [];
    }
  }

  Future<List<RemotePlaylist>> playlists() async {
    if (!isSignedIn) return const [];
    return [
      for (final p in await _webClient.libraryPlaylists())
        RemotePlaylist(id: p.id, title: p.title, count: p.count, thumbnailUrl: p.thumbnailUrl),
    ];
  }

  /// What YouTube Music shows as "Liked music".
  Future<List<Track>> likedMusic() async {
    if (!isSignedIn) return const [];
    return _webTracks(await _webClient.playlistTracks('LM', limit: _maxItems));
  }

  /// Songs YouTube Music would play after [seed] (its radio), without the seed itself.
  Future<List<Track>> upNext(Track seed) async {
    final rows = await _browseClient.radio(seed.videoId!);
    return _webTracks(rows.where((r) => r.videoId != seed.videoId).toList());
  }

  /// Public albums and playlists opened lately: going back to one, or
  /// opening it again, shows it at once. (Library playlists can be edited,
  /// so those are always fetched.)
  final _publicPages = <String, (DateTime, Future<List<Track>>)>{};

  /// Songs of a playlist from the library or of a public album / playlist.
  Future<List<Track>> collectionTracks(RemotePlaylist p) async {
    final browseId = p.browseId;
    if (browseId != null) {
      final hit = _publicPages[browseId];
      if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 30)) return hit.$2;
      final future = _browseClient.browseTracks(browseId, limit: _maxItems).then(_webTracks);
      _publicPages[browseId] = (DateTime.now(), future);
      if (_publicPages.length > 50) _publicPages.remove(_publicPages.keys.first);
      future.then<void>((_) {}, onError: (Object _) => _publicPages.remove(browseId)); // retry next time
      return future;
    }
    return playlistTracks(p.id);
  }

  Future<List<Track>> playlistTracks(String playlistId) async =>
      _webTracks(await _browseClient.playlistTracks(playlistId, limit: _maxItems));

  static String _describe(Object e) => switch (e) {
    YtMusicWebError(:final message) => message,
    TimeoutException() => 'The request timed out. Try again.',
    SocketException() || http.ClientException() => 'Network error. Check your connection.',
    _ => e.toString(),
  };

  @override
  void dispose() {
    _web?.close();
    _public.close();
    super.dispose();
  }
}
