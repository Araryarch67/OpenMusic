import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import 'audio_engine.dart';
import 'cue_sheet.dart';
import 'discord_presence.dart';
import 'metadata.dart';
import 'youtube_audio_source.dart';
import 'youtube_music_account.dart';
import 'youtube_importer.dart';
import 'youtube_stream.dart';
import 'ytdlp.dart';

/// Owns the audio player, the library and the play queue.
class PlayerController extends ChangeNotifier {
  PlayerController() {
    _subs.add(
      // just_audio re-emits the sequence state with every position update
      // (several times a second); only a real queue / song change matters here.
      player.sequenceStateStream
          .distinct(
            (a, b) =>
                a.currentIndex == b.currentIndex &&
                a.loopMode == b.loopMode &&
                a.shuffleModeEnabled == b.shuffleModeEnabled &&
                listEquals(a.sequence, b.sequence),
          )
          .listen((_) {
            _maybeAutoplay();
            _prefetchNext();
            _recordRecent();
            _updatePresence();
            notifyListeners();
          }),
    );
    _subs.add(
      player.playerStateStream.listen((_) {
        _recordRecent();
        _updatePresence();
        notifyListeners();
      }),
    );
    _subs.add(player.durationStream.listen(_correctDuration));
    _subs.add(player.errorStream.listen(_onPlaybackError));
    // Seeks move the Discord progress bar; track/play-state changes are covered above.
    _subs.add(player.positionDiscontinuityStream.listen((_) => _updatePresence(force: true)));
  }

  static const _autoplayKey = 'autoplay.v1';

  bool _autoplay = true;

  /// Like YouTube Music: when the queue runs out, keep going with similar songs.
  bool get autoplay => _autoplay;

  Future<void> setAutoplay(bool value) async {
    _autoplay = value;
    notifyListeners();
    _maybeAutoplay();
    await (await SharedPreferences.getInstance()).setBool(_autoplayKey, value);
  }

  /// Songs the queue gained from autoplay (the queue page labels them).
  final Set<String> _autoplayed = {};
  bool isAutoplayed(Track t) => _autoplayed.contains(t.id);

  String? _autoplaySeed;
  bool _extending = false;

  /// Near the end of the queue (last two songs), appends YouTube Music's
  /// "Up next" for the current song. Streamed songs only: radio needs a video id.
  void _maybeAutoplay() {
    if (!_autoplay || _extending || player.loopMode != LoopMode.off) return;
    final current = currentTrack;
    if (current == null || !current.isRemote || _autoplaySeed == current.id) return;
    final q = queue;
    final at = q.indexWhere((t) => t.id == current.id);
    if (at < 0 || at < q.length - 2) return;
    _autoplaySeed = current.id;
    _extending = true;
    ytMusic
        .upNext(current)
        .then((similar) async {
          final have = {for (final t in queue) t.id, ..._recentIds.take(30)};
          final fresh = similar.where((t) => have.add(t.id)).take(25).toList();
          if (fresh.isEmpty || !_autoplay) return;
          _autoplayed.addAll(fresh.map((t) => t.id));
          _ordered = [..._ordered, ...fresh];
          await player.addAudioSources([for (final t in fresh) _sourceFor(t)]);
          notifyListeners();
        })
        .catchError((Object e) {
          debugPrint('Autoplay failed: $e');
          _autoplaySeed = null; // try again on the next song change
        })
        .whenComplete(() => _extending = false);
  }

  /// Plays [seed] followed by its radio, like "Start radio" in YouTube Music.
  Future<void> startRadio(Track seed) async {
    await playList([seed], 0, from: '${seed.title} radio');
    _autoplaySeed = null;
    _maybeAutoplay();
  }

  static const _discordAppId = '1561368591297941655';
  static const _discordKey = 'discord.enabled';

  final DiscordPresence discord = DiscordPresence(_discordAppId);

  bool get discordEnabled => discord.enabled;

  Future<void> setDiscordEnabled(bool value) async {
    discord.enabled = value;
    _updatePresence(force: true);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_discordKey, value);
  }

  String? _presenceKey;

  void _updatePresence({bool force = false}) {
    final track = currentTrack;
    // Skip no-op updates (playerStateStream fires on every buffering change).
    final key = '${track?.id}|${player.playing}|${player.duration}';
    if (key == _presenceKey && !force) return;
    _presenceKey = key;
    discord.update(track: track, playing: player.playing, position: player.position, duration: player.duration);
  }

  static const _libraryKey = 'library.v1';
  static const _playlistsKey = 'playlists.v1';
  static const _recentRemoteKey = 'recent.remote.v1';
  static const _recentKey = 'recent.v1';
  static const _maxRecent = 24;

  final AudioPlayer player = AudioPlayer();

  late final YoutubeImporter youtube = YoutubeImporter(onTrackReady: (t) => _addTracks([t]));

  /// Equalizer, output device, gapless, leveling and the signal path (desktop).
  final AudioEngine audio = AudioEngine();

  /// Signed-in YouTube Music library (official OAuth + YouTube Data API).
  final YoutubeMusicAccount ytMusic = YoutubeMusicAccount();
  final List<StreamSubscription<dynamic>> _subs = [];

  List<Track> _library = [];
  List<Track> get library => List.unmodifiable(_library);

  List<String> _recentIds = [];

  /// Human-readable name of whatever the queue was started from.
  String? playingFrom;

  bool _scanning = false;
  bool get scanning => _scanning;

  Track? get currentTrack => player.sequenceState.currentSource?.tag as Track?;

  List<Track> get queue => player.sequenceState.effectiveSequence.map((s) => s.tag as Track).toList();

  /// Tracks after the current one in play order.
  List<Track> get upNext {
    final q = queue;
    final i = q.indexWhere((t) => t.id == currentTrack?.id);
    return i < 0 ? q : q.sublist(i + 1);
  }

  final _errors = StreamController<String>.broadcast();

  /// Human-readable playback failures (a stream that wouldn't resolve, a file that's gone).
  Stream<String> get errors => _errors.stream;

  /// A stream that fails to resolve shouldn't stall the whole queue: report it and move on.
  void _onPlaybackError(PlayerException e) {
    final title = currentTrack?.title;
    _errors.add('Couldn\'t play ${title ?? 'this song'}${e.message == null ? '' : ': ${e.message}'}');
    if (player.hasNext) {
      player.seekToNext().then((_) => player.play(), onError: (Object _) {});
    }
  }

  /// Looks up the stream of the next two songs ahead of time, so skipping
  /// to a YouTube song doesn't wait on yt-dlp. Cached, so repeats are free.
  void _prefetchNext() {
    final seq = player.sequenceState;
    final at = seq.currentIndex;
    if (at == null) return;
    for (final s in seq.sequence.skip(at + 1).take(2)) {
      final t = s.tag as Track;
      if (t.isRemote && downloadedCopy(t) == null) _resolveAhead(t.videoId!);
    }
  }

  /// Looks a song's stream up in advance (cached), so it starts right away.
  static void _resolveAhead(String videoId) =>
      (YtDlp.supported ? YtDlp.resolve(videoId) : YoutubeStream.resolve(videoId)).ignore();

  /// Whether the play button has something to start: the queue, or the local library.
  bool get canPlay => player.audioSources.isNotEmpty || _library.isNotEmpty;

  bool get isPlaying => player.playing;
  bool get isBuffering =>
      player.processingState == ProcessingState.loading || player.processingState == ProcessingState.buffering;
  bool get shuffle => _shuffled;
  LoopMode get loopMode => player.loopMode;

  /// Folder scanning needs real filesystem paths, which mobile sandboxes don't expose.
  bool get canScanFolders => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  // ── Derived library views ────────────────────────────────────────────────

  List<Track> get recentlyAdded => [..._library]..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  /// Streamed songs played recently (they aren't in the library, so they're remembered here).
  Map<String, Track> _recentRemote = {};

  /// Library and YouTube Music songs together, most recent first.
  List<Track> get recentlyPlayed {
    final byId = {for (final t in _library) t.id: t, ..._recentRemote};
    return [for (final id in _recentIds) ?byId[id]];
  }

  Collection get allSongs => Collection(
    kind: CollectionKind.allSongs,
    title: 'All Songs',
    subtitle: '${_library.length} ${_library.length == 1 ? 'song' : 'songs'}',
    tracks: [..._library]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())),
  );

  /// Everything imported from YouTube, newest first.
  Collection? get youtubeDownloads {
    final tracks = _library.where((t) => t.sourceUrl != null).toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    if (tracks.isEmpty) return null;
    return Collection(
      kind: CollectionKind.youtube,
      title: 'From YouTube',
      subtitle: '${tracks.length} ${tracks.length == 1 ? 'song' : 'songs'}',
      tracks: tracks,
    );
  }

  /// Bumped on in-place library edits; replacing [_library] invalidates by identity.
  int _libraryEdits = 0;
  (List<Track>, int)? _groupedFor;
  List<Collection> _albums = const [];
  List<Collection> _artists = const [];

  /// Albums and artists are regrouped only when the library changed, not on
  /// every rebuild (search runs this on each keystroke).
  void _regroup() {
    final g = _groupedFor;
    if (g != null && identical(g.$1, _library) && g.$2 == _libraryEdits) return;
    _groupedFor = (_library, _libraryEdits);
    _albums = _groupAlbums();
    _artists = _groupArtists();
  }

  // ── OpenMusic playlists ──────────────────────────────────────────────────

  List<UserPlaylist> _playlists = [];
  List<UserPlaylist> get playlists => List.unmodifiable(_playlists);

  Collection playlistCollection(UserPlaylist p) => Collection(
    kind: CollectionKind.playlist,
    id: p.id,
    title: p.name,
    subtitle: '${p.tracks.length} ${p.tracks.length == 1 ? 'song' : 'songs'}',
    tracks: p.tracks,
  );

  Collection? playlistById(String? id) => _playlists.where((p) => p.id == id).map(playlistCollection).firstOrNull;

  Future<void> _savePlaylists() async => (await SharedPreferences.getInstance()).setString(
    _playlistsKey,
    jsonEncode([for (final p in _playlists) p.toJson()]),
  );

  void _updatePlaylist(String id, UserPlaylist Function(UserPlaylist p) change) {
    _playlists = [for (final p in _playlists) p.id == id ? change(p) : p];
    notifyListeners();
    unawaited(_savePlaylists());
  }

  UserPlaylist createPlaylist(String name, {List<Track> tracks = const []}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final p = UserPlaylist(id: 'pl$now', name: name, tracks: _unique(tracks), createdAt: now);
    _playlists = [p, ..._playlists];
    notifyListeners();
    unawaited(_savePlaylists());
    return p;
  }

  void renamePlaylist(String id, String name) => _updatePlaylist(id, (p) => p.copyWith(name: name));

  void deletePlaylist(String id) {
    _playlists = _playlists.where((p) => p.id != id).toList();
    notifyListeners();
    unawaited(_savePlaylists());
  }

  /// Adds songs to the end, skipping ones already in it. Returns how many were added.
  int addToPlaylist(String id, List<Track> tracks) {
    var added = 0;
    _updatePlaylist(id, (p) {
      final next = _unique([...p.tracks, ...tracks]);
      added = next.length - p.tracks.length;
      return p.copyWith(tracks: next);
    });
    return added;
  }

  void removeFromPlaylist(String id, Track track) => _updatePlaylist(
    id,
    (p) => p.copyWith(
      tracks: [
        for (final t in p.tracks)
          if (t.id != track.id) t,
      ],
    ),
  );

  void movePlaylistItem(String id, int from, int to) => _updatePlaylist(id, (p) {
    final list = [...p.tracks];
    final t = list.removeAt(from);
    list.insert(to.clamp(0, list.length), t);
    return p.copyWith(tracks: list);
  });

  static List<Track> _unique(List<Track> tracks) {
    final seen = <String>{};
    return [
      for (final t in tracks)
        if (seen.add(t.id)) t,
    ];
  }

  // ── Offline copies ───────────────────────────────────────────────────────

  /// A YouTube song that was also downloaded plays from the file: no network, no buffering.
  Track? downloadedCopy(Track t) {
    final id = t.videoId;
    if (id == null) return null;
    return _library.where((l) => _videoIdOf(l.sourceUrl) == id).firstOrNull;
  }

  /// `watch?v=<id>` or `youtu.be/<id>`.
  static String? _videoIdOf(String? url) {
    final u = url == null ? null : Uri.tryParse(url);
    if (u == null) return null;
    return u.queryParameters['v'] ?? (u.host.endsWith('youtu.be') ? u.pathSegments.firstOrNull : null);
  }

  /// Whether [t] can play without internet.
  bool isOffline(Track t) => !t.isRemote || downloadedCopy(t) != null;

  List<Collection> get albums {
    _regroup();
    return _albums;
  }

  List<Collection> get artists {
    _regroup();
    return _artists;
  }

  List<Collection> _groupAlbums() {
    final groups = <String, List<Track>>{};
    for (final t in _library) {
      final key = t.albumKey;
      if (key != null) (groups[key] ??= []).add(t);
    }
    return [
      for (final tracks in groups.values)
        Collection(
          kind: CollectionKind.album,
          title: tracks.first.album!,
          subtitle: tracks.first.artist,
          tracks: tracks..sort(compareAlbumOrder),
        ),
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  List<Collection> _groupArtists() {
    final groups = <String, List<Track>>{};
    for (final t in _library) {
      if (t.artist != Track.unknownArtist) (groups[t.artist] ??= []).add(t);
    }
    return [
      for (final e in groups.entries)
        Collection(
          kind: CollectionKind.artist,
          title: e.key,
          subtitle: '${e.value.length} ${e.value.length == 1 ? 'song' : 'songs'}',
          tracks: e.value
            ..sort((a, b) {
              final byAlbum = (a.album ?? '').compareTo(b.album ?? '');
              return byAlbum != 0 ? byAlbum : compareAlbumOrder(a, b);
            }),
        ),
    ]..sort((a, b) => b.tracks.length.compareTo(a.tracks.length));
  }

  Collection? artistNamed(String name) => artists.where((a) => a.title == name).firstOrNull;

  Collection? albumOf(Track track) => albums.where((a) => a.tracks.any((t) => t.id == track.id)).firstOrNull;

  List<Track> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _library
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q) ||
              (t.album?.toLowerCase().contains(q) ?? false),
        )
        .toList();
  }

  final _searches = <String, Future<List<Track>>>{};

  /// Songs on YouTube matching [query]; they stream when played. No sign-in needed.
  /// Recent queries are answered from memory, and the top hit's stream is
  /// looked up ahead of time so it starts the moment it's clicked.
  Future<List<Track>> searchYoutube(String query) {
    final key = query.trim().toLowerCase();
    final cached = _searches.remove(key);
    if (cached != null) return _searches[key] = cached; // most recent last
    final future = _searchYoutube(query);
    _searches[key] = future;
    if (_searches.length > 40) _searches.remove(_searches.keys.first);
    future.then<void>(
      (tracks) {
        final top = tracks.firstOrNull?.videoId;
        if (top != null) _resolveAhead(top);
      },
      onError: (Object _) {
        _searches.remove(key);
      },
    );
    return future;
  }

  /// YouTube Music's own song search first; plain YouTube search if that fails.
  Future<List<Track>> _searchYoutube(String query) async {
    try {
      final songs = await ytMusic.searchSongs(query);
      if (songs.isNotEmpty) return songs;
    } catch (e) {
      debugPrint('YouTube Music search failed, using YouTube: $e');
    }
    final results = await youtube.client.search.search('$query song');
    return [
      for (final v in results.take(20))
        () {
          final names = YoutubeImporter.parseTitle(v.title, v.author);
          return Track.youtube(
            videoId: v.id.value,
            title: names.title,
            artist: names.artist,
            duration: v.duration,
            artworkUrl: v.thumbnails.highResUrl,
          );
        }(),
    ];
  }

  /// Bit-perfect means no digital volume: pin it at 100% while that mode is on.
  void _fixVolumeForBitPerfect() {
    if (audio.bitPerfect && player.volume != 1) player.setVolume(1);
    notifyListeners();
  }

  // ── Persistence & import ─────────────────────────────────────────────────

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_libraryKey);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _library = await Future.wait(list.map(Track.fromJson).map(YoutubeImporter.relocate));
    }
    _recentIds = prefs.getStringList(_recentKey) ?? [];
    try {
      _playlists = [
        for (final j in jsonDecode(prefs.getString(_playlistsKey) ?? '[]') as List)
          UserPlaylist.fromJson((j as Map).cast()),
      ];
      _recentRemote = {
        for (final j in jsonDecode(prefs.getString(_recentRemoteKey) ?? '[]') as List)
          Track.fromJson((j as Map).cast()).id: Track.fromJson(j.cast()),
      };
    } catch (e) {
      debugPrint('Ignoring unreadable playlists: $e');
    }
    discord.enabled = prefs.getBool(_discordKey) ?? true;
    _autoplay = prefs.getBool(_autoplayKey) ?? true;
    await ytMusic.load();
    await audio.load();
    unawaited(Metadata.probeTagTools().then((_) => notifyListeners()));
    audio.addListener(_fixVolumeForBitPerfect);
    _fixVolumeForBitPerfect();
    notifyListeners();
    unawaited(_enrichUntagged());
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_libraryKey, jsonEncode(_library.map((t) => t.toJson()).toList()));
  }

  /// Only counts tracks that actually start playing, not ones the queue passes through while loading.
  void _recordRecent() {
    final id = currentTrack?.id;
    if (id == null || !player.playing || (_recentIds.isNotEmpty && _recentIds.first == id)) return;
    _recentIds = [id, ..._recentIds.where((r) => r != id)].take(_maxRecent).toList();
    final current = currentTrack;
    if (current != null && current.isRemote) {
      _recentRemote = {
        for (final e in _recentRemote.entries)
          if (_recentIds.contains(e.key)) e.key: e.value,
        current.id: current,
      };
    }
    SharedPreferences.getInstance().then((p) {
      p.setStringList(_recentKey, _recentIds);
      p.setString(_recentRemoteKey, jsonEncode([for (final t in _recentRemote.values) t.toJson()]));
    });
  }

  /// Tag-based durations are estimates (e.g. CBR MP3s without a Xing header);
  /// the decoder's value is authoritative, so persist it once known.
  void _correctDuration(Duration? actual) {
    final track = currentTrack;
    if (actual == null || track == null) return;
    final known = track.duration;
    if (known != null && (known - actual).abs() < const Duration(seconds: 1)) return;
    final i = _library.indexWhere((t) => t.id == track.id);
    if (i < 0) return;
    _library[i] = _library[i].copyWith(duration: actual);
    _libraryEdits++;
    notifyListeners();
    _save();
  }

  Future<int> pickFiles() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [...Track.audioExtensions, 'cue'],
      dialogTitle: 'Add music',
    );
    final cues = files.where((f) => f.name.toLowerCase().endsWith('.cue') && f.path != null);
    final split = await _readCues([for (final f in cues) File(f.path!)]);
    return _addTracks([
      ...split.tracks,
      for (final f in files)
        if (!f.name.toLowerCase().endsWith('.cue') && !split.covers.contains(f.path))
          Track.fromUri(f.uri, displayName: f.name),
    ]);
  }

  /// Songs from cue sheets; a sheet that can't be read is skipped (its audio file then shows as one track).
  Future<({List<Track> tracks, Set<String> covers})> _readCues(List<File> cues) async {
    final tracks = <Track>[];
    final covers = <String>{};
    for (final cue in cues) {
      try {
        final r = CueSheet.read(cue);
        tracks.addAll(r.tracks);
        covers.addAll(r.covers);
      } catch (e) {
        debugPrint('Skipping cue sheet ${cue.path}: $e');
      }
    }
    return (tracks: tracks, covers: covers);
  }

  Future<int> pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Add music folder');
    if (dir == null) return 0;
    final entries = Directory(dir).list(recursive: true, followLinks: false);
    final tracks = <Track>[];
    final cues = <File>[];
    await for (final e in entries) {
      if (e is! File) continue;
      if (Track.isAudioPath(e.path)) tracks.add(Track.fromUri(Uri.file(e.path)));
      if (e.path.toLowerCase().endsWith('.cue')) cues.add(e);
    }
    final split = await _readCues(cues);
    tracks.removeWhere((t) => split.covers.contains(t.path));
    tracks.sort((a, b) => a.id.compareTo(b.id));
    return _addTracks([...tracks, ...split.tracks]);
  }

  Future<int> _addTracks(Iterable<Track> tracks) async {
    final known = _library.map((t) => t.id).toSet();
    final fresh = tracks.where((t) => known.add(t.id)).toList();
    if (fresh.isEmpty) return 0;
    _library = [..._library, ...fresh];
    notifyListeners();
    await _save();
    unawaited(_enrichUntagged());
    return fresh.length;
  }

  /// Reads embedded tags for any track that hasn't been scanned yet.
  Future<void> _enrichUntagged() async {
    if (_scanning) return;
    _scanning = true;
    notifyListeners();
    try {
      var pending = _library.where((t) => !t.tagged).toList();
      while (pending.isNotEmpty) {
        var sinceNotify = 0;
        for (final track in pending) {
          final enriched = await Metadata.enrich(track);
          final i = _library.indexWhere((t) => t.id == track.id);
          if (i >= 0) _library[i] = enriched;
          _libraryEdits++;
          if (++sinceNotify == 25) {
            sinceNotify = 0;
            notifyListeners();
          }
        }
        await _save();
        // Pick up anything imported while we were scanning.
        pending = _library.where((t) => !t.tagged).toList();
      }
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  /// Writes new tags into [track]'s file and refreshes it in the library.
  Future<void> editTags(Track track, TagEdit edit) async {
    final updated = await Metadata.writeTags(track, edit);
    final i = _library.indexWhere((t) => t.id == track.id);
    if (i >= 0) _library[i] = updated;
    _libraryEdits++;
    notifyListeners();
    await _save();
  }

  Future<void> removeTrack(Track track) async {
    _library = _library.where((t) => t.id != track.id).toList();
    notifyListeners();
    await _save();
  }

  // ── Playback ─────────────────────────────────────────────────────────────

  /// The queue in its original order; the player holds the shuffled copy.
  ///
  /// Shuffle is done here, not with just_audio's shuffle(): the desktop
  /// backend (media_kit / mpv) has no setShuffleOrder, so that call throws there.
  List<Track> _ordered = const [];
  bool _shuffled = false;
  final _random = math.Random();

  AudioSource _sourceFor(Track t) {
    if (t.isRemote) {
      final local = downloadedCopy(t);
      if (local != null) return AudioSource.uri(local.uri, tag: t);
      return YoutubeAudioSource(t.videoId!, yt: youtube.client, tag: t);
    }
    return t.isCueTrack
        ? ClippingAudioSource(child: AudioSource.uri(t.uri), start: t.start, end: t.end, tag: t)
        : AudioSource.uri(t.uri, tag: t);
  }

  /// [first] followed by everything else in random order.
  List<Track> _shuffledFrom(List<Track> tracks, int first) => [
    tracks[first],
    ...([...tracks]..removeAt(first))..shuffle(_random),
  ];

  Future<void> _load(List<Track> order, int index, {Duration? position}) =>
      player.setAudioSources([for (final t in order) _sourceFor(t)], initialIndex: index, initialPosition: position);

  /// Replaces the queue with [tracks] and starts playing at [index].
  Future<void> playList(List<Track> tracks, int index, {String? from, bool shuffled = false}) async {
    if (tracks.isEmpty) return;
    playingFrom = from;
    _autoplayed.clear();
    _autoplaySeed = null;
    _ordered = List.of(tracks);
    _shuffled = shuffled;
    try {
      await _load(shuffled ? _shuffledFrom(tracks, index) : tracks, shuffled ? 0 : index);
      unawaited(player.play());
    } on PlayerException catch (e) {
      debugPrint('Playback failed: ${e.message}');
      _errors.add('Couldn\'t play ${tracks[index].title}${e.message == null ? '' : ': ${e.message}'}');
    }
    notifyListeners();
  }

  Future<void> playCollection(Collection c, {int index = 0, bool shuffled = false}) =>
      playList(c.tracks, shuffled ? _random.nextInt(c.tracks.length) : index, from: c.title, shuffled: shuffled);

  /// True when [c] is what the queue was started from.
  bool isPlayingFrom(Collection c) => playingFrom == c.title && c.tracks.any((t) => t.id == currentTrack?.id);

  Future<void> playQueueItem(Track track) async {
    final index = player.sequenceState.sequence.indexWhere((s) => (s.tag as Track).id == track.id);
    if (index < 0) return;
    await player.seek(Duration.zero, index: index);
    unawaited(player.play());
  }

  /// Puts [tracks] right after the current song ("Play next").
  Future<void> playNext(List<Track> tracks) async {
    final current = currentTrack;
    final at = player.sequenceState.currentIndex;
    if (current == null || at == null) return playList(tracks, 0);
    final inOrder = _ordered.indexWhere((t) => t.id == current.id);
    _ordered = [..._ordered]..insertAll(inOrder < 0 ? _ordered.length : inOrder + 1, tracks);
    await player.insertAudioSources(at + 1, [for (final t in tracks) _sourceFor(t)]);
    notifyListeners();
  }

  /// Puts [tracks] at the end of the queue ("Add to queue").
  Future<void> addToQueue(List<Track> tracks) async {
    if (currentTrack == null) return playList(tracks, 0);
    _ordered = [..._ordered, ...tracks];
    await player.addAudioSources([for (final t in tracks) _sourceFor(t)]);
    notifyListeners();
  }

  /// Stops and empties the queue: the mini player and the notification go away.
  Future<void> closePlayer() async {
    await player.stop();
    await player.clearAudioSources();
    _ordered = const [];
    _autoplayed.clear();
    _autoplaySeed = null;
    playingFrom = null;
    notifyListeners();
  }

  Future<void> togglePlay() async {
    if (player.audioSources.isEmpty) {
      if (canPlay) await playCollection(allSongs);
    } else if (player.playing && player.processingState != ProcessingState.completed) {
      await player.pause();
    } else {
      // At the end of the queue play() would do nothing: start it over.
      if (player.processingState == ProcessingState.completed) await player.seek(Duration.zero, index: 0);
      unawaited(player.play());
    }
  }

  Future<void> next() => player.seekToNext();

  /// Restarts the current track unless we're near the beginning.
  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  /// Reorders the rest of the queue (or restores it) without interrupting the current song for long.
  Future<void> toggleShuffle() async {
    final current = currentTrack;
    if (current == null || _ordered.isEmpty) return;
    final enable = !_shuffled;
    final at = _ordered.indexWhere((t) => t.id == current.id);
    if (at < 0) return;
    final wasPlaying = player.playing;
    final position = player.position;
    _shuffled = enable;
    notifyListeners();
    await _load(enable ? _shuffledFrom(_ordered, at) : _ordered, enable ? 0 : at, position: position);
    if (wasPlaying) unawaited(player.play());
  }

  Future<void> cycleLoopMode() => player.setLoopMode(switch (player.loopMode) {
    LoopMode.off => LoopMode.all,
    LoopMode.all => LoopMode.one,
    LoopMode.one => LoopMode.off,
  });

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    _errors.close();
    youtube.dispose();
    ytMusic.dispose();
    audio.dispose();
    discord.dispose();
    super.dispose();
  }
}

/// Makes the [PlayerController] available to the widget tree.
class PlayerScope extends InheritedNotifier<PlayerController> {
  const PlayerScope({super.key, required PlayerController controller, required super.child})
    : super(notifier: controller);

  static PlayerController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerScope>()!.notifier!;

  /// Access without subscribing to rebuilds (for callbacks).
  static PlayerController read(BuildContext context) => context.getInheritedWidgetOfExactType<PlayerScope>()!.notifier!;
}
