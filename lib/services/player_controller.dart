import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import 'discord_presence.dart';
import 'metadata.dart';
import 'youtube_audio_source.dart';
import 'youtube_music_account.dart';
import 'youtube_importer.dart';

/// Where Home, Search and Library get their music from.
enum MusicSource {
  local('Local'),
  youtubeMusic('YouTube Music');

  const MusicSource(this.label);
  final String label;
}

/// Owns the audio player, the library and the play queue.
class PlayerController extends ChangeNotifier {
  PlayerController() {
    _subs.add(
      player.sequenceStateStream.listen((_) {
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
    // Seeks move the Discord progress bar; track/play-state changes are covered above.
    _subs.add(player.positionDiscontinuityStream.listen((_) => _updatePresence(force: true)));
  }

  static const _sourceKey = 'source.v1';

  MusicSource _source = MusicSource.local;
  MusicSource get source => _source;

  Future<void> setSource(MusicSource value) async {
    if (value == _source) return;
    _source = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_sourceKey, value.name);
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
  static const _recentKey = 'recent.v1';
  static const _maxRecent = 24;

  final AudioPlayer player = AudioPlayer();

  late final YoutubeImporter youtube = YoutubeImporter(onTrackReady: (t) => _addTracks([t]));

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

  bool get isPlaying => player.playing;
  bool get isBuffering =>
      player.processingState == ProcessingState.loading || player.processingState == ProcessingState.buffering;
  bool get shuffle => player.shuffleModeEnabled;
  LoopMode get loopMode => player.loopMode;

  /// Folder scanning needs real filesystem paths, which mobile sandboxes don't expose.
  bool get canScanFolders => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  // ── Derived library views ────────────────────────────────────────────────

  List<Track> get recentlyAdded => [..._library]..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  List<Track> get recentlyPlayed {
    final byId = {for (final t in _library) t.id: t};
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

  List<Collection> get albums {
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

  List<Collection> get artists {
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

  /// Songs on YouTube matching [query]; they stream when played. No sign-in needed.
  Future<List<Track>> searchYoutube(String query) async {
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
    final raw = prefs.getString(_libraryKey);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _library = await Future.wait(list.map(Track.fromJson).map(YoutubeImporter.relocate));
    }
    _recentIds = prefs.getStringList(_recentKey) ?? [];
    discord.enabled = prefs.getBool(_discordKey) ?? true;
    _source = MusicSource.values.asNameMap()[prefs.getString(_sourceKey)] ?? MusicSource.local;
    await ytMusic.load();
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
    SharedPreferences.getInstance().then((p) => p.setStringList(_recentKey, _recentIds));
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
    notifyListeners();
    _save();
  }

  Future<int> pickFiles() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: Track.audioExtensions.toList(),
      dialogTitle: 'Add music',
    );
    return _addTracks(files.map((f) => Track.fromUri(f.uri, displayName: f.name)));
  }

  Future<int> pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Add music folder');
    if (dir == null) return 0;
    final entries = Directory(dir).list(recursive: true, followLinks: false);
    final tracks = <Track>[];
    await for (final e in entries) {
      if (e is File && Track.isAudioPath(e.path)) tracks.add(Track.fromUri(Uri.file(e.path)));
    }
    tracks.sort((a, b) => a.id.compareTo(b.id));
    return _addTracks(tracks);
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

  Future<void> removeTrack(Track track) async {
    _library = _library.where((t) => t.id != track.id).toList();
    notifyListeners();
    await _save();
  }

  // ── Playback ─────────────────────────────────────────────────────────────

  /// Replaces the queue with [tracks] and starts playing at [index].
  Future<void> playList(List<Track> tracks, int index, {String? from, bool shuffled = false}) async {
    if (tracks.isEmpty) return;
    playingFrom = from;
    try {
      await player.setShuffleModeEnabled(false);
      await player.setAudioSources([
        for (final t in tracks)
          t.isRemote ? YoutubeAudioSource(t.videoId!, yt: youtube.client, tag: t) : AudioSource.uri(t.uri, tag: t),
      ], initialIndex: index);
      if (shuffled) {
        await player.shuffle();
        await player.setShuffleModeEnabled(true);
      }
      unawaited(player.play());
    } on PlayerException catch (e) {
      debugPrint('Playback failed: ${e.message}');
    }
  }

  Future<void> playCollection(Collection c, {int index = 0, bool shuffled = false}) => playList(
    c.tracks,
    shuffled ? (DateTime.now().microsecond % c.tracks.length) : index,
    from: c.title,
    shuffled: shuffled,
  );

  /// True when [c] is what the queue was started from.
  bool isPlayingFrom(Collection c) => playingFrom == c.title && c.tracks.any((t) => t.id == currentTrack?.id);

  Future<void> playQueueItem(Track track) async {
    final index = player.sequenceState.sequence.indexWhere((s) => (s.tag as Track).id == track.id);
    if (index < 0) return;
    await player.seek(Duration.zero, index: index);
    unawaited(player.play());
  }

  Future<void> togglePlay() async {
    if (player.audioSources.isEmpty) {
      await playCollection(allSongs);
    } else if (player.playing) {
      await player.pause();
    } else {
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

  Future<void> toggleShuffle() async {
    final enable = !player.shuffleModeEnabled;
    if (enable) await player.shuffle();
    await player.setShuffleModeEnabled(enable);
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
    youtube.dispose();
    ytMusic.dispose();
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
