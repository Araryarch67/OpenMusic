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

  void _onController() {
    if (_c.currentTrack?.id != _shownId) _publishItem();
    if (_c.player.playing != _shownPlaying) _publishState();
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
      duration: _c.player.duration ?? t.duration,
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
    _shownPlaying = p.playing;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (p.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (p.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: p.playing,
        updatePosition: p.position,
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
  Future<void> play() => _c.player.play();

  @override
  Future<void> pause() => _c.player.pause();

  @override
  Future<void> stop() => _c.player.pause();

  @override
  Future<void> seek(Duration position) => _c.player.seek(position);

  @override
  Future<void> skipToNext() => _c.next();

  @override
  Future<void> skipToPrevious() => _c.previous();
}
