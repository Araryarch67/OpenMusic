import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'metadata.dart';
import 'player_controller.dart';

/// The system's media controls: Android's notification and lock screen,
/// Control Center on iOS / macOS, and MPRIS on Linux (the desktop's media
/// widget, media keys, `playerctl`). Mirrors [PlayerController]; every button
/// goes back to it.
class MediaSession extends BaseAudioHandler with SeekHandler {
  MediaSession._(this._c) {
    final p = _c.player;
    // Clients extrapolate the position from the last update and the speed, so
    // state changes and seeks are enough; no per-tick updates.
    _subs.addAll([
      p.playerStateStream.listen((_) => _publishState()),
      p.positionDiscontinuityStream.listen((_) => _publishState()),
      p.durationStream.listen((_) => _publishItem()),
    ]);
    _c.addListener(_onController);
    _publishItem();
    _publishState();
  }

  /// Starts the session; null where the platform has none (Windows).
  static Future<MediaSession?> start(PlayerController c) async {
    if (Platform.isWindows) return null;
    try {
      return await AudioService.init(
        builder: () => MediaSession._(c),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'dev.openmusic.openmusic.playback',
          // Also the player's name in MPRIS (Linux media widgets).
          androidNotificationChannelName: 'OpenMusic',
          androidNotificationIcon: 'mipmap/ic_launcher_monochrome',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
    } catch (e) {
      debugPrint('Media controls unavailable: $e');
      return null;
    }
  }

  final PlayerController _c;
  final _subs = <StreamSubscription<Object?>>[];
  String? _shownId;
  bool? _shownPlaying;

  /// Swiped away from Recents: the session is put away until something plays.
  bool _closed = false;

  void _onController() {
    if (_c.currentTrack?.id != _shownId) _publishItem();
    if (_c.isPlaying != _shownPlaying) _publishState();
  }

  Future<void> _publishItem() async {
    final t = _c.currentTrack;
    _shownId = t?.id;
    if (t == null) return mediaItem.add(null);
    final item = MediaItem(
      id: t.id,
      title: t.title,
      artist: t.artist,
      album: t.album,
      duration: _c.duration ?? t.duration,
      artUri: t.isRemote && t.artworkUrl != null ? Uri.tryParse(t.artworkUrl!) : null,
    );
    mediaItem.add(item);
    if (item.artUri == null) {
      // Local cover art lives in the file's tags; the system needs a file or URL.
      final art = await _artFile(t);
      if (art != null && _shownId == t.id) mediaItem.add(item.copyWith(artUri: art.uri));
    }
  }

  void _publishState() {
    final p = _c.player;
    final playing = _c.isPlaying;
    if (playing) _closed = false;
    // Android's service forgets the song when it's stopped and started again,
    // which left a notification with only the app's name. Starting to play
    // sends the song along every time.
    if (playing && _shownPlaying != true && mediaItem.value != null) mediaItem.add(mediaItem.value);
    _shownPlaying = playing;
    // Idle tells Android the session is over: it stops the service and takes
    // the notification down. Only when nothing is left to play, not when the
    // player is idle for a moment between or after songs.
    final over = _closed || _c.currentTrack == null;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: over
            ? AudioProcessingState.idle
            : _c.casting
            ? (_c.isBuffering ? AudioProcessingState.buffering : AudioProcessingState.ready)
            : switch (p.processingState) {
                ProcessingState.idle => AudioProcessingState.ready,
                ProcessingState.loading => AudioProcessingState.loading,
                ProcessingState.buffering => AudioProcessingState.buffering,
                ProcessingState.ready => AudioProcessingState.ready,
                ProcessingState.completed => AudioProcessingState.completed,
              },
        playing: playing,
        updatePosition: _c.position,
        bufferedPosition: p.bufferedPosition,
        speed: p.speed,
      ),
    );
  }

  static Directory? _artDir;

  static Future<File?> _artFile(Track t) async {
    final bytes = Metadata.cachedArtwork(t) ?? await Metadata.artwork(t);
    if (bytes == null) return null;
    _artDir ??= Directory('${(await getTemporaryDirectory()).path}/openmusic-art');
    final file = File('${_artDir!.path}/${sha1.convert(bytes)}.img');
    if (!file.existsSync()) {
      await _artDir!.create(recursive: true);
      await file.writeAsBytes(bytes);
    }
    return file;
  }

  @override
  Future<void> play() => _c.play();

  @override
  Future<void> pause() => _c.pause();

  @override
  Future<void> stop() => _c.pause();

  /// The app was swiped away from Recents. Closing it stops the music and
  /// takes the notification down; leaving it with Home keeps playing.
  @override
  Future<void> onTaskRemoved() async {
    _closed = true;
    await _c.pause();
    _publishState();
  }

  @override
  Future<void> seek(Duration position) => _c.seek(position);

  @override
  Future<void> skipToNext() => _c.next();

  @override
  Future<void> skipToPrevious() => _c.previous();
}
