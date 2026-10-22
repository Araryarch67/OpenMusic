import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/track.dart';

/// Discord Rich Presence over Discord's local IPC socket (no SDK, no network).
///
/// Protocol: frames of `[int32 LE opcode][int32 LE length][JSON]` over
/// `discord-ipc-N` (a Unix socket on Linux/macOS, a named pipe on Windows).
/// Opcode 0 is the handshake; opcode 1 carries commands such as SET_ACTIVITY.
class DiscordPresence {
  DiscordPresence(this.clientId, {@visibleForTesting Iterable<String> Function()? socketPaths})
    : _socketPaths = socketPaths ?? _candidatePaths;

  final String clientId;
  final Iterable<String> Function() _socketPaths;

  /// Discord allows 5 activity updates per 20 s; stay comfortably under that.
  static const _minInterval = Duration(seconds: 4);

  _IpcConnection? _conn;
  bool _connecting = false;
  DateTime _lastSent = DateTime(0);
  Timer? _pending;
  Map<String, dynamic>? _wanted;
  bool _enabled = true;

  static bool get supported => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  bool get enabled => _enabled;
  set enabled(bool value) {
    _enabled = value;
    if (!value) {
      _wanted = null;
      _send(null);
    }
  }

  /// Shows [track] as playing from [position], or clears the presence when
  /// [track] is null or paused.
  void update({required Track? track, required bool playing, required Duration position, Duration? duration}) {
    if (!supported || !_enabled) return;
    _wanted = track == null || !playing ? null : _activity(track, position, duration);
    // Nothing shown yet and nothing to show: don't wake Discord up just to clear.
    if (_wanted == null && _conn == null) {
      _pending?.cancel();
      return;
    }
    _schedule();
  }

  void _schedule() {
    _pending?.cancel();
    final wait = _minInterval - DateTime.now().difference(_lastSent);
    _pending = Timer(wait.isNegative ? Duration.zero : wait, () => _send(_wanted));
  }

  Map<String, dynamic> _activity(Track t, Duration position, Duration? duration) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = now - position.inMilliseconds;
    final videoId = t.videoId ?? _videoIdFrom(t.sourceUrl);
    final cover = t.artworkUrl ?? (videoId == null ? null : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg');
    final listenUrl = videoId == null ? null : 'https://music.youtube.com/watch?v=$videoId';
    return {
      'type': 2, // "Listening to"
      'status_display_type': 2, // member list shows the song title, not the app name
      'details': _clip(t.title),
      'state': _clip(t.artist),
      'timestamps': {'start': start, 'end': ?(duration == null ? null : start + duration.inMilliseconds)},
      'assets': {
        // Remote URLs work as images; local files fall back to an art asset
        // named "openmusic" uploaded in the Discord developer portal.
        'large_image': cover ?? 'openmusic',
        'large_text': _clip(t.album ?? 'OpenMusic'),
      },
      if (listenUrl != null)
        'buttons': [
          {'label': 'Listen on YouTube Music', 'url': listenUrl},
        ],
    };
  }

  static String? _videoIdFrom(String? url) => url == null ? null : Uri.tryParse(url)?.queryParameters['v'];

  /// Discord requires 2–128 characters.
  static String _clip(String s) {
    final t = s.trim();
    if (t.length < 2) return t.padRight(2, ' ');
    return t.length > 128 ? '${t.substring(0, 127)}…' : t;
  }

  Future<void> _send(Map<String, dynamic>? activity) async {
    _lastSent = DateTime.now();
    final conn = await _ensureConnected();
    if (conn == null) return;
    try {
      conn.send(1, {
        'cmd': 'SET_ACTIVITY',
        'args': {'pid': pid, 'activity': activity},
        'nonce': '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}',
      });
    } catch (e) {
      debugPrint('Discord presence: send failed ($e); will reconnect');
      _drop();
    }
  }

  Future<_IpcConnection?> _ensureConnected() async {
    if (_conn != null) return _conn;
    if (_connecting) return null;
    _connecting = true;
    try {
      for (final path in _socketPaths()) {
        final conn = await _IpcConnection.open(path, onClosed: _drop);
        if (conn == null) continue;
        conn.send(0, {'v': 1, 'client_id': clientId});
        if (await conn.ready.timeout(const Duration(seconds: 3), onTimeout: () => false)) {
          return _conn = conn;
        }
        conn.close();
      }
      return null; // Discord isn't running; try again on the next update.
    } finally {
      _connecting = false;
    }
  }

  void _drop() {
    _conn?.close();
    _conn = null;
  }

  static Iterable<String> _candidatePaths() sync* {
    if (Platform.isWindows) {
      for (var i = 0; i < 10; i++) {
        yield r'\\?\pipe\discord-ipc-'
            '$i';
      }
      return;
    }
    final env = Platform.environment;
    final bases = {?env['XDG_RUNTIME_DIR'], ?env['TMPDIR'], ?env['TMP'], ?env['TEMP'], '/tmp'};
    // Plain installs, then Flatpak and Snap sandboxes.
    const subdirs = [
      '',
      'app/com.discordapp.Discord/',
      'app/dev.vencord.Vesktop/',
      'snap.discord/',
      '.flatpak/com.discordapp.Discord/xdg-run/',
    ];
    for (final base in bases) {
      for (final sub in subdirs) {
        for (var i = 0; i < 10; i++) {
          yield '$base/${sub}discord-ipc-$i';
        }
      }
    }
  }

  void dispose() {
    _pending?.cancel();
    final conn = _conn;
    if (conn != null) {
      try {
        conn.send(1, {
          'cmd': 'SET_ACTIVITY',
          'args': {'pid': pid, 'activity': null},
          'nonce': 'bye',
        });
      } catch (_) {}
    }
    _drop();
  }
}

/// One framed IPC connection (socket or named pipe).
class _IpcConnection {
  _IpcConnection._(this._write, this._closer);

  final void Function(List<int> bytes) _write;
  final void Function() _closer;
  final _ready = Completer<bool>();
  final _buffer = BytesBuilder();
  bool _closed = false;

  Future<bool> get ready => _ready.future;

  static Future<_IpcConnection?> open(String path, {required void Function() onClosed}) async {
    try {
      if (Platform.isWindows) {
        final pipe = await File(path).open(mode: FileMode.append);
        late final _IpcConnection conn;
        // A RandomAccessFile runs one operation at a time: a read left waiting for
        // Discord made every write fail ("an async operation is currently pending").
        // Discord answers each message with one frame, so each write reads its answer.
        var queue = Future<void>.value();
        void enqueue(Future<void> Function() op) =>
            queue = queue.then((_) => op()).catchError((Object _) => conn._onClosed(onClosed));
        conn = _IpcConnection._(
          (b) => enqueue(() async {
            await pipe.writeFrom(b);
            await conn._readFrame(pipe).timeout(const Duration(seconds: 5));
          }),
          () => enqueue(pipe.close),
        );
        return conn;
      }
      if (!File(path).existsSync() && FileSystemEntity.typeSync(path) != FileSystemEntityType.unixDomainSock) {
        return null;
      }
      final socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(seconds: 2));
      final conn = _IpcConnection._(socket.add, socket.destroy);
      socket.listen(conn._onData, onDone: () => conn._onClosed(onClosed), onError: (_) => conn._onClosed(onClosed));
      return conn;
    } catch (_) {
      return null;
    }
  }

  /// Reads one frame (Windows: the answer to the message just written).
  Future<void> _readFrame(RandomAccessFile pipe) async {
    Future<Uint8List> exactly(int n) async {
      final out = BytesBuilder(copy: false);
      while (out.length < n) {
        final chunk = await pipe.read(n - out.length);
        if (chunk.isEmpty) throw const FileSystemException('Discord closed the pipe');
        out.add(chunk);
      }
      return out.takeBytes();
    }

    final header = await exactly(8);
    final length = ByteData.sublistView(header).getInt32(4, Endian.little);
    _onData([...header, ...await exactly(length)]);
  }

  void _onClosed(void Function() onClosed) {
    if (!_ready.isCompleted) _ready.complete(false);
    if (!_closed) onClosed();
    _closed = true;
  }

  void _onData(List<int> data) {
    _buffer.add(data);
    var bytes = _buffer.toBytes();
    while (bytes.length >= 8) {
      final header = ByteData.sublistView(bytes, 0, 8);
      final op = header.getInt32(0, Endian.little);
      final len = header.getInt32(4, Endian.little);
      if (bytes.length < 8 + len) break;
      final payload = jsonDecode(utf8.decode(bytes.sublist(8, 8 + len))) as Map<String, dynamic>;
      _handle(op, payload);
      bytes = bytes.sublist(8 + len);
    }
    _buffer
      ..clear()
      ..add(bytes);
  }

  void _handle(int op, Map<String, dynamic> payload) {
    if (op == 1 && payload['evt'] == 'READY' && !_ready.isCompleted) _ready.complete(true);
    if (payload['evt'] == 'ERROR') debugPrint('Discord presence error: ${payload['data']}');
    if (op == 2) _ready.isCompleted ? null : _ready.complete(false); // CLOSE: bad client id, etc.
  }

  void send(int op, Map<String, dynamic> payload) {
    if (_closed) throw const SocketException('closed');
    final body = utf8.encode(jsonEncode(payload));
    final header = ByteData(8)
      ..setInt32(0, op, Endian.little)
      ..setInt32(4, body.length, Endian.little);
    _write([...header.buffer.asUint8List(), ...body]);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _closer();
    } catch (_) {}
  }
}
