import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'airplay.dart';
import 'dlna.dart';

/// One song to play on a renderer.
class CastItem {
  const CastItem({
    required this.key,
    required this.media,
    required this.title,
    this.artist,
    this.album,
    this.duration,
    this.art,
  });

  /// Identifies the song (the track id).
  final String key;

  /// What to serve when playing from [from]: only media that can't be
  /// byte-seeked ([CastTranscode]) is asked for anything but zero.
  final CastMedia Function(Duration from) media;
  final String title;
  final String? artist;
  final String? album;
  final Duration? duration;

  /// The cover, fetched when the song is sent (renderers can't read our tags).
  final Future<Uint8List?> Function()? art;
}

/// A TV or speaker music can be sent to.
sealed class CastTarget {
  const CastTarget();
  String get id;
  String get name;
  bool get hasVolume;

  @override
  bool operator ==(Object other) => other is CastTarget && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A DLNA / UPnP renderer (TVs, receivers, many speakers).
class DlnaTarget extends CastTarget {
  const DlnaTarget(this.renderer);
  final DlnaRenderer renderer;

  @override
  String get id => 'dlna:${renderer.id}';
  @override
  String get name => renderer.name;
  @override
  bool get hasVolume => renderer.hasVolume;
}

/// A classic AirPlay speaker.
class AirPlayTarget extends CastTarget {
  const AirPlayTarget(this.device);
  final AirPlayDevice device;

  @override
  String get id => 'airplay:${device.id}';
  @override
  String get name => device.name;
  @override
  bool get hasVolume => true;
}

/// Plays songs on a TV or speaker and follows what it does.
///
/// DLNA renderers play on their own and send no events we could rely on, so
/// it asks every second (position, pause from the TV's remote, the end of a
/// song). AirPlay speakers are fed by this app ([AirPlaySession]), which
/// knows all that itself.
class Cast extends ChangeNotifier {
  Cast({
    required this.onEnded,
    required this.onError,
    this.pollEvery = const Duration(seconds: 1),
    this.airPlay = _never,
  });

  static bool _never() => false;

  /// Whether AirPlay can be offered (it needs the `ffmpeg` command to decode).
  final bool Function() airPlay;

  /// The song played to its end on the renderer.
  final VoidCallback onEnded;

  /// Something went wrong, in words for the user.
  final void Function(String message) onError;

  final Duration pollEvery;

  // ── Finding devices ──────────────────────────────────────────────────────

  List<CastTarget> _devices = const [];
  List<CastTarget> get devices => _devices;

  bool _searching = false;
  bool get searching => _searching;

  final _searches = <StreamSubscription<CastTarget>>[];

  /// Looks for TVs and speakers on the network (DLNA and AirPlay) for a few
  /// seconds. Devices found by an earlier search stay listed.
  Future<void> search() async {
    if (_searching) return;
    _searching = true;
    notifyListeners();
    final sources = <Stream<CastTarget>>[
      Dlna.discover().map(DlnaTarget.new),
      if (airPlay()) AirPlay.discover().where((d) => d.usable).map(AirPlayTarget.new),
    ];
    Future<void> follow(Stream<CastTarget> source) {
      final done = Completer<void>();
      _searches.add(
        source.listen(
          (t) {
            _devices = [..._devices.where((d) => d != t), t]..sort((a, b) => a.name.compareTo(b.name));
            notifyListeners();
          },
          onDone: done.complete,
          onError: (Object e) => debugPrint('Device search: $e'),
        ),
      );
      return done.future;
    }

    await Future.wait(sources.map(follow));
    _searches.clear();
    _searching = false;
    notifyListeners();
  }

  // ── The session ──────────────────────────────────────────────────────────

  final CastServer _server = CastServer();
  DlnaControl? _control;
  InternetAddress? _host;
  Timer? _poll;

  AirPlaySession? _airplay;

  CastTarget? get target => switch ((_control, _airplay)) {
    (final c?, _) => DlnaTarget(c.renderer),
    (_, final a?) => AirPlayTarget(a.device),
    _ => null,
  };
  bool get active => _control != null || _airplay != null;

  /// Starts sending to [device]. Throws [DlnaException] (or a network
  /// error) when it can't be reached.
  Future<void> connect(CastTarget device, {DlnaControl? control}) async {
    if (target == device) return;
    await disconnect(stopRenderer: true);
    switch (device) {
      case DlnaTarget(:final renderer):
        await _connectDlna(renderer, control);
      case AirPlayTarget(device: final speaker):
        late final AirPlaySession session;
        session = AirPlaySession(
          speaker,
          onEnded: () {
            notifyListeners();
            onEnded();
          },
          onError: (message) {
            if (_airplay != session) return;
            _airplay = null;
            _item = null;
            notifyListeners();
            onError(message);
          },
        );
        try {
          await session.connect();
        } catch (e) {
          await session.close();
          throw DlnaException('Can\'t reach ${speaker.name}');
        }
        _airplay = session;
        _volume = 60;
        session.setVolume(0.6).ignore();
        notifyListeners();
    }
  }

  Future<void> _connectDlna(DlnaRenderer renderer, DlnaControl? control) async {
    final c = control ?? DlnaControl(renderer);
    try {
      _host = await CastServer.addressFor(renderer);
    } catch (e) {
      c.close();
      throw DlnaException('Can\'t reach ${renderer.name}');
    }
    _control = c;
    _failures = 0;
    _volume = null;
    if (renderer.hasVolume) {
      c.volume().then((v) {
        _volume = v;
        notifyListeners();
      }, onError: (Object _) {}).ignore();
    }
    _poll = Timer.periodic(pollEvery, (_) => _refresh());
    notifyListeners();
  }

  /// Back to this device; [stopRenderer] also stops the music over there.
  Future<void> disconnect({bool stopRenderer = true}) async {
    if (_airplay case final a?) {
      _airplay = null;
      _item = null;
      notifyListeners();
      await a.close();
      return;
    }
    final c = _control;
    if (c == null) return;
    _poll?.cancel();
    _poll = null;
    _control = null;
    _item = null;
    _playing = false;
    _loading = false;
    notifyListeners();
    if (stopRenderer) {
      try {
        await c.stop();
      } catch (_) {}
    }
    c.close();
    await _server.close();
  }

  CastItem? _item;

  /// The song on the renderer.
  String? get loadedKey => _item?.key;

  /// Where the served media starts in the song (non-seekable media is
  /// restarted from the seek point, and the renderer counts from there).
  Duration _offset = Duration.zero;
  bool _seekable = true;

  Duration _pos = Duration.zero;
  DateTime _posAt = DateTime.now();
  bool _playing = false;
  bool _loading = false;
  Duration? _duration;
  int? _volume;

  /// Set once the renderer has been seen playing the current song, so a
  /// STOPPED before that (while it's still loading) isn't taken as the end.
  bool _started = false;

  bool get playing => _airplay?.playing ?? _playing;
  bool get loading => _airplay == null && _loading;
  Duration? get duration => _item?.duration ?? _duration;

  /// 0-100, null until the renderer says (or when it has no volume control).
  int? get volume => _volume;

  /// Where the renderer is, moving smoothly between its once-a-second answers.
  Duration get position {
    if (_airplay case final a?) return a.position;
    var p = _offset + _pos;
    if (_playing) p += DateTime.now().difference(_posAt);
    final d = duration;
    return d != null && p > d ? d : p;
  }

  /// [position] [every] so often, only when it moved.
  Stream<Duration> positionTicks({Duration every = const Duration(milliseconds: 33)}) {
    Duration? last;
    return Stream<void>.periodic(every).map((_) => position).where((p) {
      final changed = p != last;
      last = p;
      return changed;
    });
  }

  int _generation = 0;

  /// Sends [item] to the renderer and starts it at [from] if [play].
  Future<void> load(CastItem item, {Duration from = Duration.zero, bool play = true}) async {
    if (_airplay case final a?) {
      _item = item;
      notifyListeners();
      try {
        await a.setMetadata(title: item.title, artist: item.artist, album: item.album);
        await a.load(_airPlaySource(item.media(Duration.zero)), duration: item.duration, from: from, play: play);
      } catch (e) {
        onError('Couldn\'t play ${item.title} on ${a.device.name}: $e');
      }
      notifyListeners();
      return;
    }
    final c = _control;
    final host = _host;
    if (c == null || host == null) return;
    final generation = ++_generation;
    _item = item;
    _started = false;
    _duration = null;
    _loading = true;
    _playing = play;
    _setPos(Duration.zero);
    var media = item.media(Duration.zero);
    _seekable = media.seekable;
    if (!_seekable && from > Duration.zero) media = item.media(from);
    _offset = _seekable ? Duration.zero : from;
    notifyListeners();
    try {
      final url = await _server.publish(media, host);
      Uri? art;
      try {
        final bytes = await item.art?.call().timeout(const Duration(seconds: 2));
        if (bytes != null && bytes.length > 4) {
          final png = bytes[0] == 0x89 && bytes[1] == 0x50;
          art = await _server.publishArt(bytes, png ? 'image/png' : 'image/jpeg', host);
        }
      } catch (_) {}
      if (generation != _generation) return;
      final didl = DlnaControl.didl(
        url: url,
        mime: media.mime,
        title: item.title,
        artist: item.artist,
        album: item.album,
        art: art,
        duration: _seekable ? item.duration : null,
        seekable: _seekable,
      );
      // Some renderers refuse a new URI while playing.
      try {
        await c.stop();
      } catch (_) {}
      await c.setUri(url, didl);
      if (generation != _generation) return;
      if (play) await c.play();
      if (_seekable && from > Duration.zero) {
        await _seekWhenReady(c, from, generation);
      }
    } catch (e) {
      if (generation != _generation) return;
      _loading = false;
      _playing = false;
      notifyListeners();
      onError(e is DlnaException ? e.message : 'Couldn\'t play ${item.title} on ${c.renderer.name}: $e');
    }
  }

  /// Many renderers only take a seek once they have opened the stream.
  Future<void> _seekWhenReady(DlnaControl c, Duration to, int generation) async {
    for (var i = 0; i < 20 && generation == _generation; i++) {
      try {
        await c.seek(to);
        _setPos(to);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// The FFmpeg input for [media]: AirPlay sends decoded audio.
  static AirPlaySource _airPlaySource(CastMedia media) => switch (media) {
    CastFile(:final path) => AirPlaySource(input: path),
    CastStream(:final source) => AirPlaySource(
      input: 'pipe:0',
      stdin: () async* {
        final r = await source.request();
        yield* r.stream;
      },
    ),
    CastTranscode() => AirPlaySource(
      input: media.input == null ? media.path : 'pipe:0',
      stdin: media.input,
      start: media.start,
      end: media.end,
    ),
  };

  Future<void> play() async {
    if (_airplay case final a?) {
      await a.play();
      return notifyListeners();
    }
    final c = _control;
    if (c == null || _item == null) return;
    _playing = true;
    _setPos(_pos);
    notifyListeners();
    await _guard(c.play);
  }

  Future<void> pause() async {
    if (_airplay case final a?) {
      await a.pause();
      return notifyListeners();
    }
    final c = _control;
    if (c == null) return;
    _setPos(position - _offset);
    _playing = false;
    notifyListeners();
    await _guard(c.pause);
  }

  Future<void> seek(Duration to) async {
    if (_airplay case final a?) {
      await a.seek(to);
      return notifyListeners();
    }
    final c = _control;
    final item = _item;
    if (c == null || item == null) return;
    if (!_seekable) return load(item, from: to, play: _playing);
    _setPos(to);
    notifyListeners();
    await _guard(() => c.seek(to));
  }

  Future<void> setVolume(int volume) async {
    if (_airplay case final a?) {
      _volume = volume.clamp(0, 100);
      notifyListeners();
      return a.setVolume(_volume! / 100);
    }
    final c = _control;
    if (c == null || !c.renderer.hasVolume) return;
    _volume = volume.clamp(0, 100);
    notifyListeners();
    await _guard(() => c.setVolume(_volume!));
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      onError(e is DlnaException ? e.message : 'Lost touch with ${target?.name ?? 'the device'}');
    }
  }

  void _setPos(Duration p) {
    _pos = p;
    _posAt = DateTime.now();
  }

  int _failures = 0;
  bool _refreshing = false;

  Future<void> _refresh() async {
    final c = _control;
    if (c == null || _refreshing) return;
    _refreshing = true;
    final generation = _generation;
    try {
      final state = await c.transportState();
      final info = await c.positionInfo();
      if (c != _control || generation != _generation) return;
      _failures = 0;
      final wasPlaying = _playing;
      final wasLoading = _loading;
      final oldDuration = _duration;
      // Before this answer: renderers often reset to 0:00 once stopped.
      final last = _offset + _pos;
      final playing = state == 'PLAYING';
      if (playing) _started = true;
      _loading = state == 'TRANSITIONING' || (!_started && _playing && state != 'PAUSED_PLAYBACK');
      if (!_loading) _playing = playing;
      if (info.position case final p?) _setPos(p);
      if (info.duration case final d? when d > Duration.zero) _duration = _offset + d;
      final ended = _started && (state == 'STOPPED' || state == 'NO_MEDIA_PRESENT');
      if (ended) {
        _started = false;
        _playing = false;
        // A stop near the end is the song finishing; earlier, someone pressed
        // Stop on the TV, so just show it stopped.
        final d = duration;
        if (d == null || last >= d - const Duration(seconds: 10)) {
          notifyListeners();
          onEnded();
          return;
        }
      }
      if (_playing != wasPlaying || _loading != wasLoading || _duration != oldDuration) notifyListeners();
    } catch (e) {
      if (c != _control) return;
      // A few seconds of silence: the device is gone (switched off, left the network).
      if (++_failures >= 5) {
        final name = c.renderer.name;
        await disconnect(stopRenderer: false);
        onError('Lost connection to $name');
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    for (final s in _searches) {
      s.cancel();
    }
    _airplay?.close();
    _poll?.cancel();
    _control?.close();
    _server.close();
    super.dispose();
  }
}
