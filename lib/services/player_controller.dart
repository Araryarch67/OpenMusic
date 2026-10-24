import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import 'audio_engine.dart';
import 'cast.dart';
import 'cue_sheet.dart';
import 'discord_presence.dart';
import 'dlna.dart';
import 'dop.dart';
import 'ffmpeg.dart';
import 'library_store.dart';
import 'lyrics.dart';
import 'lyrics_translation.dart';
import 'metadata.dart';
import 'sacd.dart';
import 'memory_trim.dart';
import 'youtube_audio_source.dart';
import 'youtube_music_account.dart';
import 'youtube_importer.dart';
import 'youtube_stream.dart';

/// Android: "Add folder" was refused the permission to read music.
class MusicPermissionDenied implements Exception {
  const MusicPermissionDenied();
}

/// Owns the audio player, the library and the play queue.
class PlayerController extends ChangeNotifier {
  PlayerController() {
    // The first YouTube song then needs one request, not two.
    YoutubeStream.warmUp();
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
            _castFollow();
            _followDop();
            _prefetchNext();
            _recordRecent();
            _updatePresence();
            MemoryTrim.schedule();
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
    final seq = player.sequenceState;
    final at = seq.currentIndex;
    if (at == null || at < seq.sequence.length - 2) return;
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
    final key = '${track?.id}|$isPlaying|$duration';
    if (key == _presenceKey && !force) return;
    _presenceKey = key;
    discord.update(track: track, playing: isPlaying, position: position, duration: duration);
  }

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

  /// The library, read-only (a view, not a copy: widgets ask for it on every build).
  List<Track> get library => _views.library;

  List<String> _recentIds = [];

  /// Human-readable name of whatever the queue was started from.
  String? playingFrom;

  bool _scanning = false;
  bool get scanning => _scanning;

  Track? get currentTrack => player.sequenceState.currentSource?.tag as Track?;

  List<Track> get queue => player.sequenceState.effectiveSequence.map((s) => s.tag as Track).toList();

  /// Whether anything is queued (without copying the queue, as [queue] does).
  bool get hasQueue => player.sequenceState.sequence.isNotEmpty;

  /// Tracks after the current one in play order.
  List<Track> get upNext {
    final seq = player.sequenceState;
    return [for (final s in seq.sequence.skip((seq.currentIndex ?? -1) + 1)) s.tag as Track];
  }

  /// The song after the current one, if any.
  Track? get nextTrack {
    final seq = player.sequenceState;
    final i = seq.currentIndex;
    return i == null || i + 1 >= seq.sequence.length ? null : seq.sequence[i + 1].tag as Track;
  }

  final _errors = StreamController<String>.broadcast();

  /// Human-readable playback failures (a stream that wouldn't resolve, a file that's gone).
  Stream<String> get errors => _errors.stream;

  String? _lastError;
  DateTime _lastErrorAt = DateTime(0);

  /// A stream that fails to resolve shouldn't stall the whole queue: report it and move on.
  void _onPlaybackError(PlayerException e) {
    // mpv reports one failure in several lines ("cannot open file", "failed
    // to open"): handle it once, or the queue would skip past good songs too.
    final now = DateTime.now();
    if (e.message == _lastError && now.difference(_lastErrorAt) < const Duration(seconds: 3)) return;
    _lastError = e.message;
    _lastErrorAt = now;
    // The player's current index can still be the song before (it fails while
    // opening): mpv names the file it couldn't open, so go by that.
    final seq = player.sequenceState.sequence;
    final failed = RegExp(r"'([^']+)'|open (.+)\.$").firstMatch(e.message ?? '');
    final path = failed?.group(1) ?? failed?.group(2);
    final at = path == null ? -1 : seq.indexWhere((s) => (s.tag as Track).path == path);
    final title = at >= 0 ? (seq[at].tag as Track).title : currentTrack?.title;
    // In plain words: mpv's own message (paths, stream URLs) only goes to the log.
    debugPrint('Playback error: ${e.message}');
    _errors.add('Couldn\'t play ${title ?? 'this song'}');
    // Repeat-one would retry the same broken song forever: skip it all the same.
    final next = _neighbour(1, from: at >= 0 ? at : null);
    if (next != null) {
      player.seek(Duration.zero, index: next).then((_) => _play(), onError: (Object _) {});
    }
  }

  /// Looks up the stream of the next two songs ahead of time, so skipping
  /// to a YouTube song doesn't wait. Cached, so repeats are free.
  void _prefetchNext() {
    final seq = player.sequenceState;
    final at = seq.currentIndex;
    if (at == null) return;
    for (final s in seq.sequence.skip(at + 1).take(2)) {
      final t = s.tag as Track;
      if (t.isRemote && downloadedCopy(t) == null) _resolveAhead(t.videoId!);
    }
  }

  /// Looks a song's stream up in advance and fetches its first seconds, so it
  /// starts right away.
  static void _resolveAhead(String videoId) => YoutubeAudioSource.preload(videoId).ignore();

  /// Whether the play button has something to start: the queue, or the local library.
  bool get canPlay => player.audioSources.isNotEmpty || _library.isNotEmpty;

  bool get isPlaying => casting ? cast.playing : player.playing;
  bool get isBuffering => casting
      ? cast.loading
      : player.processingState == ProcessingState.loading || player.processingState == ProcessingState.buffering;

  /// Where the current song is, here or on the cast device.
  Duration get position => casting ? cast.position : player.position;

  Duration? get duration => casting ? cast.duration ?? player.duration : player.duration;

  Future<void> seek(Duration to) => casting ? cast.seek(to) : player.seek(to);

  Future<void> play() => _play();

  Future<void> pause() => casting ? cast.pause() : player.pause();

  /// 0-1: where the volume slider sits, for this device or the cast device.
  ///
  /// This device's gain is the cube of it, as with mpv's own volume (which the
  /// app's 64-bit filter stands in for off the system mixer): with linear gain
  /// halfway is only −6 dB, and all the audible change is crammed into the
  /// bottom of the slider. A cast device's volume is its own 0-100 scale,
  /// already shaped by the device.
  double get volume => casting ? (cast.volume ?? 0) / 100 : _level.value;

  /// This device's [volume]: the one level the slider shows, every song plays
  /// at and the next launch starts from. Only [setVolume] changes it, so
  /// just_audio's own volume (which its interruption handling doubles on
  /// Android once a notification has ducked it) can't drift from the slider.
  ValueListenable<double> get volumeLevel => _level;
  final _level = ValueNotifier<double>(1);

  static double levelOfGain(double gain) => gain <= 0 ? 0 : math.pow(gain.clamp(0, 1), 1 / 3).toDouble();
  static double gainOfLevel(double level) => math.pow(level.clamp(0, 1), 3).toDouble();

  bool get canSetVolume => !casting || (cast.target?.hasVolume ?? false);

  Future<void> setVolume(double v) {
    v = v.clamp(0, 1);
    if (casting) return cast.setVolume((v * 100).round());
    _level.value = v;
    _saveVolume?.cancel();
    _saveVolume = Timer(const Duration(milliseconds: 500), _storeVolume);
    return _playAt(v);
  }

  Future<void> _storeVolume() async => (await SharedPreferences.getInstance()).setDouble(_volumeKey, _level.value);

  /// The engine applies it to mpv (desktop and Android); elsewhere it is just_audio's.
  Future<void> _playAt(double level) =>
      AudioEngine.supported ? audio.setVolume(gainOfLevel(level)) : player.setVolume(gainOfLevel(level));

  static const _volumeKey = 'volume.v1';
  Timer? _saveVolume;

  /// The level Unmute goes back to.
  double? _unmuteTo;

  /// Remembers the level a slider drag starts from, for Unmute after dragging to 0.
  void volumeDragStarted() {
    if (volume > 0) _unmuteTo = volume;
  }

  Future<void> toggleMute() {
    if (volume > 0) {
      _unmuteTo = volume;
      return setVolume(0);
    }
    return setVolume(_unmuteTo ?? 1);
  }

  /// Ctrl+↑ / Ctrl+↓ and the mouse wheel over the volume slider.
  Future<void> nudgeVolume(double by) async {
    if (canSetVolume && audio.dopPlaying == null) await setVolume(((volume + by) * 20).round() / 20);
  }

  /// [position] often enough that a seek bar glides instead of ticking (here
  /// or on the cast device). That's a step of half a pixel on the widest bar,
  /// not every frame: a 4-minute song moves a 1200 px bar 5 px a second, so
  /// updating at 60 fps redrew the window for nothing the eye could see.
  Stream<Duration> smoothPosition() => _positionStream(smooth: true);

  /// [position] a few times a second, for views that rebuild a lot per tick.
  Stream<Duration> positionUpdates() => _positionStream(smooth: false);

  Stream<Duration> _positionStream({required bool smooth}) {
    StreamSubscription<Duration>? sub;
    bool? wasCasting;
    late final StreamController<Duration> out;
    void attach() {
      if (wasCasting == casting) return;
      wasCasting = casting;
      sub?.cancel();
      sub =
          (casting
                  ? cast.positionTicks(every: Duration(milliseconds: smooth ? 50 : 200))
                  : smooth
                  ? player.createPositionStream(
                      // The song's length / 2400: half a pixel of a 1200 px bar.
                      steps: 2400,
                      minPeriod: const Duration(milliseconds: 16),
                      maxPeriod: const Duration(milliseconds: 250),
                    )
                  : player.positionStream)
              .listen(out.add);
    }

    out = StreamController<Duration>(
      onListen: () {
        attach();
        cast.addListener(attach);
      },
      onCancel: () {
        cast.removeListener(attach);
        return sub?.cancel();
      },
    );
    return out.stream;
  }

  bool get shuffle => _shuffled;
  LoopMode get loopMode => player.loopMode;

  /// Folder scanning needs real filesystem paths, which mobile sandboxes don't expose.
  bool get canScanFolders => Platform.isLinux || Platform.isWindows || Platform.isMacOS || Platform.isAndroid;

  // ── Derived library views ────────────────────────────────────────────────
  //
  // Worked out once per library change, not on every rebuild: Home, the
  // sidebar and every song row ask for them, and sorting or scanning the whole
  // library each time stalled every song change for tens of milliseconds.

  /// Bumped on in-place library edits; replacing [_library] invalidates by identity.
  int _libraryEdits = 0;
  _LibraryViews? _cachedViews;

  _LibraryViews get _views {
    final v = _cachedViews;
    if (v != null && identical(v.tracks, _library) && v.edits == _libraryEdits) return v;
    return _cachedViews = _LibraryViews(_library, _libraryEdits);
  }

  List<Track> get recentlyAdded => _views.recentlyAdded;

  /// Streamed songs played recently (they aren't in the library, so they're remembered here).
  Map<String, Track> _recentRemote = {};

  /// Library and YouTube Music songs together, most recent first.
  List<Track> get recentlyPlayed => [for (final id in _recentIds) ?(_recentRemote[id] ?? _views.byId[id])];

  Collection get allSongs => _views.allSongs;

  /// Everything imported from YouTube, newest first.
  Collection? get youtubeDownloads => _views.youtubeDownloads;

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
    return id == null ? null : _views.downloads[id];
  }

  /// Whether [t] can play without internet.
  bool isOffline(Track t) => !t.isRemote || downloadedCopy(t) != null;

  List<Collection> get albums => _views.albums;

  List<Collection> get artists => _views.artists;

  /// Albums and artists together, by name (the library list's "everything").
  List<Collection> get albumsAndArtists => _views.albumsAndArtists;

  Collection? artistNamed(String name) => _views.artistByName[name];

  Collection? albumOf(Track track) => _views.albumOfTrack[track.id];

  List<Track> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final v = _views;
    return [
      for (var i = 0; i < v.tracks.length; i++)
        if (v.searchKeys[i].contains(q)) v.tracks[i],
    ];
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

  // ── Persistence & import ─────────────────────────────────────────────────

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // Side by side: the library (its own file, read in the background), the
    // YouTube Music session and the audio settings.
    final library = LibraryStore.load(prefs);
    await Future.wait([library, ytMusic.load(), audio.load()]);
    // iOS moves the app's folder on updates; elsewhere downloads stay put.
    _library = Platform.isIOS ? await Future.wait((await library).map(YoutubeImporter.relocate)) : await library;
    _recentIds = prefs.getStringList(_recentKey) ?? [];
    try {
      _playlists = [
        for (final j in jsonDecode(prefs.getString(_playlistsKey) ?? '[]') as List)
          UserPlaylist.fromJson((j as Map).cast()),
      ];
      _recentRemote = {
        for (final j in jsonDecode(prefs.getString(_recentRemoteKey) ?? '[]') as List)
          if (Track.fromJson((j as Map).cast()) case final t) t.id: t,
      };
    } catch (e) {
      debugPrint('Ignoring unreadable playlists: $e');
    }
    discord.enabled = prefs.getBool(_discordKey) ?? true;
    _autoplay = prefs.getBool(_autoplayKey) ?? true;
    final loop = LoopMode.values.asNameMap()[prefs.getString(_loopKey)];
    if (loop != null && loop != LoopMode.off) await player.setLoopMode(loop);
    final level = prefs.getDouble(_volumeKey);
    if (level != null) {
      _level.value = level.clamp(0, 1);
      await _playAt(_level.value);
    }
    Ffmpeg.onDownload = _errors.add;
    unawaited(Metadata.probeTagTools().then((_) => notifyListeners()));
    unawaited(LyricsTranslation.load());
    unawaited(LyricsService.loadBetterLyricsKey());
    audio.addListener(notifyListeners);
    _dopWasActive = audio.dopActive;
    audio.addListener(_onAudioSettings);
    notifyListeners();
    unawaited(_enrichUntagged());
  }

  Future<void> _save() async => LibraryStore.save(await SharedPreferences.getInstance(), _library);

  /// Only counts tracks that actually start playing, not ones the queue passes through while loading.
  void _recordRecent() {
    final id = currentTrack?.id;
    if (id == null || !isPlaying || (_recentIds.isNotEmpty && _recentIds.first == id)) return;
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
  /// the decoder's value is authoritative, so persist it once known. Not a
  /// zero: mpv reports one while a file opens, and the song's length was
  /// saved as 0:00 (a song saved so is put right the next time it plays).
  void _correctDuration(Duration? actual) {
    final track = currentTrack;
    if (actual == null || actual <= Duration.zero || track == null) return;
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
      allowedExtensions: [...Track.audioExtensions, 'cue', 'iso'],
      dialogTitle: 'Add music',
    );
    final cues = files.where((f) => f.name.toLowerCase().endsWith('.cue') && f.path != null);
    final split = await _readCues([for (final f in cues) File(f.path!)]);
    final isos = [
      for (final f in files)
        if (f.name.toLowerCase().endsWith('.iso') && f.path != null) f.path!,
    ];
    return _addTracks([
      ...split.tracks,
      ...await _readSacds(isos),
      for (final f in files)
        if (!f.name.toLowerCase().endsWith('.cue') &&
            !f.name.toLowerCase().endsWith('.iso') &&
            !split.covers.contains(f.path))
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

  /// Songs on SACD images; other ISOs (DVDs, data discs) are skipped.
  static Future<List<Track>> _readSacds(List<String> paths) async {
    if (paths.isEmpty) return const [];
    return Isolate.run(() => [for (final p in paths) ...?SacdDisc.read(p)?.tracks()]);
  }

  Future<int> pickFolder() async {
    // Android: the songs are read where they are, which takes the permission to read music.
    if (Platform.isAndroid && await _musicPermission.invokeMethod<bool>('request') != true) {
      throw const MusicPermissionDenied();
    }
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Add music folder');
    if (dir == null) return 0;
    return scanFolder(dir);
  }

  static const _musicPermission = MethodChannel('openmusic/music_permission');

  /// Adds every song, cue sheet and SACD image under [dir].
  Future<int> scanFolder(String dir) async {
    final entries = Directory(dir).list(recursive: true, followLinks: false);
    final tracks = <Track>[];
    final cues = <File>[];
    final isos = <String>[];
    await for (final e in entries) {
      if (e is! File) continue;
      if (Track.isAudioPath(e.path)) tracks.add(Track.fromUri(Uri.file(e.path)));
      if (e.path.toLowerCase().endsWith('.cue')) cues.add(e);
      if (e.path.toLowerCase().endsWith('.iso')) isos.add(e.path);
    }
    final split = await _readCues(cues);
    tracks.removeWhere((t) => split.covers.contains(t.path));
    tracks.sort((a, b) => a.id.compareTo(b.id));
    return _addTracks([...tracks, ...split.tracks, ...await _readSacds(isos)]);
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
        // Where each song sits, worked out again only if the library was replaced meanwhile.
        List<Track>? indexed;
        var at = <String, int>{};
        var notified = DateTime.now();
        await Metadata.enrichAll(pending, (batch) {
          if (!identical(indexed, _library)) {
            indexed = _library;
            at = {for (var i = 0; i < _library.length; i++) _library[i].id: i};
          }
          for (final t in batch) {
            if (at[t.id] case final i?) _library[i] = t;
          }
          _libraryEdits++;
          // A few times a second is plenty for the counts and covers filling in.
          if (DateTime.now().difference(notified) > const Duration(milliseconds: 400)) {
            notified = DateTime.now();
            notifyListeners();
          }
        });
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
    if (SacdDisc.isSacdTrack(t)) {
      final found = SacdDisc.find(t);
      if (found != null) {
        final (disc, song) = found;
        // DoP needs the DSD itself; DST-compressed discs play as PCM.
        if (audio.dopActive && !disc.area.dst) return DopAudioSource(SacdDsd(disc, song), tag: t);
        return SacdAudioSource(disc, song, tag: t);
      }
    }
    if (audio.dopActive && !t.isCueTrack && t.path != null && DsdFile.isDsdPath(t.path!)) {
      final dsd = DsdFile.read(t.path!);
      if (dsd != null) return DopAudioSource(dsd, tag: t);
    }
    if (t.isRemote) {
      final local = downloadedCopy(t);
      if (local != null) return AudioSource.uri(local.uri, tag: t);
      return YoutubeAudioSource(t.videoId!, yt: youtube.client, tag: t);
    }
    return t.isCueTrack
        ? ClippingAudioSource(child: AudioSource.uri(t.uri), start: t.start, end: t.end, tag: t)
        : AudioSource.uri(t.uri, tag: t);
  }

  bool _dopWasActive = false;

  /// DoP switched on or off: rebuild the queue so DSD songs change over,
  /// from where the current one is.
  void _onAudioSettings() {
    if (audio.dopActive == _dopWasActive) return;
    _dopWasActive = audio.dopActive;
    final seq = player.sequenceState;
    final at = seq.currentIndex;
    final hasDsd = seq.sequence.any((s) {
      final t = s.tag as Track;
      return SacdDisc.isSacdTrack(t) || (t.path != null && DsdFile.isDsdPath(t.path!));
    });
    if (at == null || !hasDsd) return;
    final wasPlaying = player.playing;
    final position = player.position;
    _load([for (final s in seq.sequence) s.tag as Track], at, position: position).then((_) {
      if (wasPlaying) unawaited(player.play());
    }, onError: (Object e) => debugPrint('Reloading for DoP failed: $e'));
  }

  /// Tells the engine when a DoP stream plays (it holds volume at 100%).
  void _followDop() {
    final source = player.sequenceState.currentSource;
    audio.dopPlaying = source is DopAudioSource ? DsdPlayback(source.dsd.bitRate) : null;
  }

  /// [first] followed by everything else in random order.
  List<Track> _shuffledFrom(List<Track> tracks, int first) => [
    tracks[first],
    ...([...tracks]..removeAt(first))..shuffle(_random),
  ];

  Future<void> _load(List<Track> order, int index, {Duration? position}) async {
    try {
      await player.setAudioSources(
        [for (final t in order) _sourceFor(t)],
        initialIndex: index,
        initialPosition: position,
      );
    } on PlayerInterruptedException {
      // Something newer took over (another song picked, or a broken one skipped): fine.
    }
  }

  /// Replaces the queue with [tracks] and starts playing at [index].
  Future<void> playList(List<Track> tracks, int index, {String? from, bool shuffled = false}) async {
    if (tracks.isEmpty) return;
    playingFrom = from;
    _autoplayed.clear();
    _autoplaySeed = null;
    _ordered = List.of(tracks);
    _shuffled = shuffled;
    try {
      // A song that fails to open never finishes loading: stop waiting once
      // the player reports it ([_onPlaybackError] moves on from there).
      final failed = Completer<bool>();
      final sub = player.errorStream.listen((_) => failed.isCompleted ? null : failed.complete(false));
      final loaded = await Future.any([
        _load(shuffled ? _shuffledFrom(tracks, index) : tracks, shuffled ? 0 : index).then((_) => true),
        failed.future,
      ]).whenComplete(sub.cancel);
      if (loaded) unawaited(_play(restart: true));
    } on PlayerException catch (e) {
      debugPrint('Playback failed: ${e.message}');
      _errors.add('Couldn\'t play ${tracks[index].title}');
    }
    notifyListeners();
  }

  Future<void> playCollection(Collection c, {int index = 0, bool shuffled = false}) =>
      playList(c.tracks, shuffled ? _random.nextInt(c.tracks.length) : index, from: c.title, shuffled: shuffled);

  /// True when [c] is what the queue was started from.
  bool isPlayingFrom(Collection c) {
    if (playingFrom != c.title) return false;
    final id = currentTrack?.id;
    return c.tracks.any((t) => t.id == id);
  }

  Future<void> playQueueItem(Track track) async {
    final index = player.sequenceState.sequence.indexWhere((s) => (s.tag as Track).id == track.id);
    if (index < 0) return;
    await player.seek(Duration.zero, index: index);
    unawaited(_play(restart: true));
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
    } else if (casting) {
      await (cast.playing ? cast.pause() : _play());
    } else if (player.playing && player.processingState != ProcessingState.completed) {
      await player.pause();
    } else {
      // At the end of the queue play() would do nothing: start it over.
      if (player.processingState == ProcessingState.completed) await player.seek(Duration.zero, index: 0);
      unawaited(player.play());
    }
  }

  /// Plays here, or on the cast device. [restart]: the song was just chosen,
  /// so start it from the top even if it's the one already on the device.
  Future<void> _play({bool restart = false}) async {
    if (!casting) return player.play();
    if (cast.loadedKey != currentTrack?.id) return _castCurrent(play: true);
    // Already sent (the queue change just did it).
    if (cast.loading) return;
    if (restart) await cast.seek(Duration.zero);
    return cast.play();
  }

  /// The song [offset] steps away in play order (the queue is already in
  /// shuffled order when shuffling). Wraps around in repeat-all.
  ///
  /// Not just_audio's next/previous index: in repeat-one those point back at
  /// the current song, so Next and Previous would only restart it.
  int? _neighbour(int offset, {int? from}) {
    final seq = player.sequenceState;
    final at = from ?? seq.currentIndex;
    final n = seq.sequence.length;
    if (at == null || n == 0) return null;
    final i = at + offset;
    if (i >= 0 && i < n) return i;
    return player.loopMode == LoopMode.all ? (i % n + n) % n : null;
  }

  bool get hasNext => _neighbour(1) != null;
  bool get hasPrevious => _neighbour(-1) != null;

  Future<void> next() async {
    final i = _neighbour(1);
    if (i != null) await player.seek(Duration.zero, index: i);
  }

  /// Restarts the current track unless we're near the beginning.
  Future<void> previous() async {
    final i = _neighbour(-1);
    if (position > const Duration(seconds: 3) || i == null) {
      await seek(Duration.zero);
    } else {
      await player.seek(Duration.zero, index: i);
    }
  }

  /// Reorders the rest of the queue (or restores it) without interrupting the current song for long.
  Future<void> toggleShuffle() async {
    final current = currentTrack;
    if (current == null || _ordered.isEmpty) return;
    final enable = !_shuffled;
    final at = _ordered.indexWhere((t) => t.id == current.id);
    if (at < 0) return;
    // While casting the device keeps playing; only the order here changes.
    final wasPlaying = player.playing;
    final position = player.position;
    _shuffled = enable;
    notifyListeners();
    await _load(enable ? _shuffledFrom(_ordered, at) : _ordered, enable ? 0 : at, position: position);
    if (wasPlaying) unawaited(player.play());
  }

  static const _loopKey = 'loop.v1';

  /// Off → repeat all → repeat one → off. Remembered, like shuffle in the
  /// streaming apps.
  Future<void> cycleLoopMode() async {
    final mode = switch (player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await player.setLoopMode(mode);
    // Repeat stops autoplay from adding songs; off lets it pick up again.
    if (mode == LoopMode.off) _maybeAutoplay();
    await (await SharedPreferences.getInstance()).setString(_loopKey, mode.name);
  }

  // ── Casting (DLNA / UPnP, AirPlay) ────────────────────────────────────────────
  //
  // The queue stays in [player], paused, while a TV or speaker plays: next,
  // previous and queue picks move it, and [_castFollow] sends the new song.

  late final Cast cast = Cast(
    onEnded: _castEnded,
    airPlay: () => Metadata.hasFfmpeg,
    onError: (message) {
      _errors.add(message);
      // The device went away: carry on here, from where it was.
      if (!casting) _updatePresence(force: true);
    },
  )..addListener(notifyListeners);

  bool get casting => cast.active;

  /// Plays on [renderer] from where this device is, or back here (null).
  Future<void> castTo(CastTarget? renderer) async {
    if (renderer == null) return _stopCasting();
    if (cast.target == renderer) return;
    final from = position;
    final wasPlaying = isPlaying;
    try {
      await cast.connect(renderer);
    } catch (e) {
      debugPrint('Casting to ${renderer.name} failed: $e');
      _errors.add('Couldn\'t reach ${renderer.name}');
      return;
    }
    await player.pause();
    if (currentTrack != null) await _castCurrent(from: from, play: wasPlaying);
    _updatePresence(force: true);
  }

  Future<void> _stopCasting() async {
    if (!casting) return;
    final from = cast.position;
    final wasPlaying = cast.playing;
    final onDevice = cast.loadedKey;
    await cast.disconnect();
    if (onDevice != null && onDevice == currentTrack?.id) await player.seek(from);
    if (wasPlaying) unawaited(player.play());
    _updatePresence(force: true);
  }

  /// Sends the current song to the cast device when the queue moves on.
  void _castFollow() {
    if (!casting || currentTrack == null || cast.loadedKey == currentTrack!.id) return;
    _castCurrent(play: true);
  }

  Future<void> _castCurrent({Duration from = Duration.zero, bool play = true}) async {
    final t = currentTrack;
    if (t == null || !casting) return;
    await cast.load(_castItem(t), from: from, play: play);
  }

  void _castEnded() {
    if (player.loopMode == LoopMode.one) {
      _castCurrent(play: true);
    } else if (_neighbour(1) case final next?) {
      player.seek(Duration.zero, index: next).then((_) => _castFollow(), onError: (Object _) {});
    }
    _updatePresence(force: true);
  }

  /// Formats nearly every renderer plays as they are.
  static const _castMimes = {
    'mp3': 'audio/mpeg',
    'flac': 'audio/flac',
    'm4a': 'audio/mp4',
    'mp4': 'audio/mp4',
    'aac': 'audio/mp4',
    'wav': 'audio/wav',
  };

  CastItem _castItem(Track t) {
    final local = t.isRemote ? downloadedCopy(t) : t;
    final path = local?.path;
    final CastMedia Function(Duration) media;
    final sacd = SacdDisc.isSacdTrack(t) ? SacdDisc.find(t) : null;
    if (sacd != null) {
      // No renderer plays DSD: FFmpeg turns the song (as DSDIFF) into FLAC.
      final source = SacdAudioSource(sacd.$1, sacd.$2);
      media = (from) => CastTranscode(path!, start: from, maxRate: 176400, input: () => source.bytes(0, source.length));
    } else if (path == null) {
      // Most TVs and speakers can't decode Opus, so YouTube songs go as AAC.
      final source = YoutubeAudioSource(t.videoId!, yt: youtube.client, aac: true);
      media = (_) => CastStream(source, 'audio/mp4');
    } else {
      final ext = path.split('.').last.toLowerCase();
      final direct = _castMimes[ext];
      if ((direct != null && !t.isCueTrack) || !Metadata.hasFfmpeg) {
        // Without ffmpeg, the device may still know the format.
        media = (_) => CastFile(path, direct ?? 'audio/${ext == 'ogg' || ext == 'oga' ? 'ogg' : ext}');
      } else {
        final dsd = ext == 'dsf' || ext == 'dff';
        media = (from) =>
            CastTranscode(path, start: (t.start ?? Duration.zero) + from, end: t.end, maxRate: dsd ? 176400 : 192000);
      }
    }
    return CastItem(
      key: t.id,
      media: media,
      title: t.title,
      artist: t.artist,
      album: t.album,
      duration: t.isCueTrack && t.end != null ? t.end! - t.start! : t.duration ?? player.duration,
      art: () => Metadata.artwork(t),
    );
  }

  bool _disposed = false;

  /// Bumped whenever the library or the OpenMusic playlists changed, for views
  /// that show only those (the library list, a collection's songs): they then
  /// skip the far more frequent changes of what's playing.
  final libraryRevision = ValueNotifier<int>(0);
  (List<Track>, int, List<UserPlaylist>)? _revisionOf;

  /// Work started in [load] (tag tools probe, tag enrichment) can finish after dispose.
  @override
  void notifyListeners() {
    if (_disposed) return;
    final seen = _revisionOf;
    if (seen == null || !identical(seen.$1, _library) || seen.$2 != _libraryEdits || !identical(seen.$3, _playlists)) {
      _revisionOf = (_library, _libraryEdits, _playlists);
      libraryRevision.value++;
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // A level set in the last half second is still kept.
    if (_saveVolume?.isActive ?? false) {
      _saveVolume!.cancel();
      _storeVolume().ignore();
    }
    MemoryTrim.stop();
    cast.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    _errors.close();
    youtube.dispose();
    ytMusic.dispose();
    audio.dispose();
    discord.dispose();
    libraryRevision.dispose();
    _level.dispose();
    super.dispose();
  }
}

/// Makes the [PlayerController] available to the widget tree.
class PlayerScope extends InheritedNotifier<PlayerController> {
  PlayerScope({super.key, required PlayerController controller, required Widget child})
    : super(
        notifier: controller,
        child: _PlayerIdentity(controller: controller, child: child),
      );

  /// The controller, rebuilding the caller on every change it notifies.
  static PlayerController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerScope>()!.notifier!;

  /// Access without subscribing to rebuilds (for callbacks).
  static PlayerController read(BuildContext context) => context.getInheritedWidgetOfExactType<PlayerScope>()!.notifier!;

  /// The controller, rebuilding the caller only if a different one takes its
  /// place (tests do that): for widgets that listen to just part of it.
  static PlayerController identity(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PlayerIdentity>()!.controller;
}

class _PlayerIdentity extends InheritedWidget {
  const _PlayerIdentity({required this.controller, required super.child});

  final PlayerController controller;

  @override
  bool updateShouldNotify(_PlayerIdentity old) => !identical(controller, old.controller);
}

/// [builder] again for each change the controller notifies, but only while
/// this part of the screen can be seen. A page covered by another (its tickers
/// are off: Home under an album, a hidden phone tab) was rebuilt and laid out
/// for every song change all the same; now it catches up once it's uncovered.
class VisiblePlayerBuilder extends StatefulWidget {
  const VisiblePlayerBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, PlayerController c) builder;

  @override
  State<VisiblePlayerBuilder> createState() => _VisiblePlayerBuilderState();
}

class _VisiblePlayerBuilderState extends State<VisiblePlayerBuilder> {
  PlayerController? _c;
  bool _visible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = PlayerScope.identity(context);
    if (!identical(c, _c)) {
      _c?.removeListener(_changed);
      _c = c..addListener(_changed);
    }
    // Runs again (and so builds) when the page is covered or uncovered.
    _visible = TickerMode.valuesOf(context).enabled;
  }

  void _changed() {
    if (_visible) setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _c!);
}

/// Rebuilds when [select] picks out something else from the controller, not
/// on each of its changes. [PlayerController] notifies for everything (a song
/// starting, play / pause, buffering, the library), several times a song; a
/// song row only cares whether it is the one playing.
class PlayerSelect<T> extends StatefulWidget {
  const PlayerSelect({super.key, required this.select, required this.builder, this.child});

  /// Compared with `==`: records of plain values work.
  final T Function(PlayerController c) select;
  final Widget Function(BuildContext context, T value, Widget? child) builder;
  final Widget? child;

  @override
  State<PlayerSelect<T>> createState() => _PlayerSelectState<T>();
}

class _PlayerSelectState<T> extends State<PlayerSelect<T>> {
  PlayerController? _c;
  late T _value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = PlayerScope.identity(context);
    if (identical(c, _c)) return;
    _c?.removeListener(_changed);
    _c = c..addListener(_changed);
    _value = widget.select(c);
  }

  @override
  void didUpdateWidget(PlayerSelect<T> old) {
    super.didUpdateWidget(old);
    // What's selected may depend on the widget's own fields (a row's song).
    _value = widget.select(_c!);
  }

  void _changed() {
    final value = widget.select(_c!);
    if (value != _value) setState(() => _value = value);
  }

  @override
  void dispose() {
    _c?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value, widget.child);
}

/// What the UI reads from one version of the library, each part worked out on
/// first use. A new library (or an in-place edit) gets a new one.
class _LibraryViews {
  _LibraryViews(this.tracks, this.edits);

  final List<Track> tracks;
  final int edits;

  late final List<Track> library = UnmodifiableListView(tracks);

  late final Map<String, Track> byId = {for (final t in tracks) t.id: t};

  /// Title, artist and album of each song in lower case, for search.
  late final List<String> searchKeys = [
    for (final t in tracks) '${t.title}\u0000${t.artist}\u0000${t.album ?? ''}'.toLowerCase(),
  ];

  late final Collection allSongs = Collection(
    kind: CollectionKind.allSongs,
    title: 'All Songs',
    subtitle: '${tracks.length} ${tracks.length == 1 ? 'song' : 'songs'}',
    tracks: _sortedBy(tracks, (t) => t.title.toLowerCase()),
  );

  late final List<Track> recentlyAdded = [...tracks]..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  late final Collection? youtubeDownloads = () {
    final downloaded = tracks.where((t) => t.sourceUrl != null).toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    if (downloaded.isEmpty) return null;
    return Collection(
      kind: CollectionKind.youtube,
      title: 'From YouTube',
      subtitle: '${downloaded.length} ${downloaded.length == 1 ? 'song' : 'songs'}',
      tracks: downloaded,
    );
  }();

  /// Video id → the first library file downloaded from it.
  late final Map<String, Track> downloads = () {
    final out = <String, Track>{};
    for (final t in tracks) {
      if (_videoIdOf(t.sourceUrl) case final id?) out.putIfAbsent(id, () => t);
    }
    return out;
  }();

  late final List<Collection> albums = () {
    final groups = <String, List<Track>>{};
    for (final t in tracks) {
      final key = t.albumKey;
      if (key != null) (groups[key] ??= []).add(t);
    }
    final albums = [
      for (final group in groups.values)
        Collection(
          kind: CollectionKind.album,
          title: group.first.album!,
          subtitle: group.first.artist,
          tracks: group..sort(compareAlbumOrder),
        ),
    ];
    return _sortedBy(albums, (a) => a.title.toLowerCase());
  }();

  late final List<Collection> artists = () {
    final groups = <String, List<Track>>{};
    for (final t in tracks) {
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
  }();

  late final Map<String, Collection> artistByName = {for (final a in artists) a.title: a};

  late final List<Collection> albumsAndArtists = _sortedBy([...albums, ...artists], (c) => c.title.toLowerCase());

  late final Map<String, Collection> albumOfTrack = {
    for (final a in albums)
      for (final t in a.tracks) t.id: a,
  };

  /// [items] sorted by [key], each key computed once; equal keys keep their order.
  static List<T> _sortedBy<T>(List<T> items, String Function(T) key) {
    final keys = [for (final i in items) key(i)];
    final order = List<int>.generate(items.length, (i) => i)
      ..sort((a, b) {
        final c = keys[a].compareTo(keys[b]);
        return c != 0 ? c : a - b;
      });
    return [for (final i in order) items[i]];
  }

  /// `watch?v=<id>` or `youtu.be/<id>`.
  static String? _videoIdOf(String? url) {
    final u = url == null ? null : Uri.tryParse(url);
    if (u == null) return null;
    return u.queryParameters['v'] ?? (u.host.endsWith('youtu.be') ? u.pathSegments.firstOrNull : null);
  }
}
