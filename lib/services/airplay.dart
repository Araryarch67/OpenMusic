import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:pointycastle/export.dart' show AESEngine, CBCBlockCipher, KeyParameter, ParametersWithIV;

/// A speaker that takes classic AirPlay (RAOP): AirPort Express, AirPlay
/// receivers in amplifiers and speakers, shairport-sync.
class AirPlayDevice {
  const AirPlayDevice({
    required this.name,
    required this.host,
    required this.port,
    this.encryptions = const {0},
    this.codecs = const {1},
  });

  final String name;
  final InternetAddress host;
  final int port;

  /// From the `et` TXT record: 0 none, 1 RSA (AirPort Express), 3+ FairPlay.
  final Set<int> encryptions;

  /// From `cn`: 0 PCM, 1 ALAC, 2 AAC...
  final Set<int> codecs;

  String get id => '${host.address}:$port';

  /// Sends in the clear when the speaker allows it, otherwise with the
  /// AirPort Express RSA key; FairPlay-only speakers (AirPlay 2) can't be used.
  bool get usable => encryptions.contains(0) || encryptions.contains(1);

  @override
  bool operator ==(Object other) => other is AirPlayDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AirPlayDevice($name, $id)';
}

abstract final class AirPlay {
  /// Speakers announcing `_raop._tcp` on the network, each once, for [timeout].
  static Stream<AirPlayDevice> discover({Duration timeout = const Duration(seconds: 4)}) async* {
    final client = MDnsClient(
      rawDatagramSocketFactory: (host, int port, {bool reuseAddress = true, bool reusePort = true, int ttl = 255}) =>
          RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: !Platform.isWindows, ttl: ttl),
    );
    try {
      await client.start();
    } catch (e) {
      debugPrint('AirPlay: no mDNS here: $e');
      return;
    }
    final seen = <String>{};
    try {
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('_raop._tcp.local'),
        timeout: timeout,
      )) {
        try {
          final srv = await client
              .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
              .first
              .timeout(const Duration(seconds: 2));
          final txt = await client
              .lookup<TxtResourceRecord>(ResourceRecordQuery.text(ptr.domainName))
              .toList()
              .timeout(const Duration(seconds: 2), onTimeout: () => const []);
          final ip = await client
              .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target))
              .first
              .timeout(const Duration(seconds: 2));
          final device = fromRecords(ptr.domainName, ip.address, srv.port, [for (final t in txt) t.text]);
          if (device != null && seen.add(device.id)) yield device;
        } catch (e) {
          debugPrint('AirPlay: ${ptr.domainName} didn\'t answer: $e');
        }
      }
    } finally {
      client.stop();
    }
  }

  /// "AABBCCDDEEFF@Kitchen._raop._tcp.local" plus TXT entries → a device.
  @visibleForTesting
  static AirPlayDevice? fromRecords(String instance, InternetAddress host, int port, List<String> txt) {
    final label = instance.split('._raop').first;
    final at = label.indexOf('@');
    final name = at < 0 ? label : label.substring(at + 1);
    final entries = <String, String>{};
    for (final line in txt.expand((t) => t.split('\n'))) {
      final eq = line.indexOf('=');
      if (eq > 0) entries[line.substring(0, eq)] = line.substring(eq + 1);
    }
    Set<int> list(String key, Set<int> fallback) {
      final v = entries[key];
      if (v == null) return fallback;
      return {for (final x in v.split(',')) ?int.tryParse(x.trim())};
    }

    final d = AirPlayDevice(
      name: name,
      host: host,
      port: port,
      encryptions: list('et', const {0}),
      codecs: list('cn', const {1}),
    );
    return d.codecs.contains(1) ? d : null;
  }
}

/// Packs 16-bit stereo PCM into ALAC frames stored uncompressed (the
/// "escape" form every ALAC decoder reads); receivers don't care that it
/// isn't compressed, and it costs nothing to make.
@visibleForTesting
Uint8List alacFrame(Uint8List pcm) {
  final frames = pcm.length ~/ 4;
  final out = _BitWriter(7 + frames * 4 + 1)
    ..write(1, 3) // channels - 1
    ..write(0, 4)
    ..write(0, 12)
    ..write(1, 1) // the frame size follows
    ..write(0, 2)
    ..write(1, 1) // not compressed
    ..write(frames, 32);
  final v = ByteData.sublistView(pcm);
  for (var i = 0; i < frames; i++) {
    out
      ..write(v.getUint16(i * 4, Endian.little), 16)
      ..write(v.getUint16(i * 4 + 2, Endian.little), 16);
  }
  out.write(7, 3); // end of frame
  return out.bytes();
}

class _BitWriter {
  _BitWriter(int capacity) : _out = Uint8List(capacity + 1);
  final Uint8List _out;
  int _bit = 0;

  void write(int value, int bits) {
    for (var i = bits - 1; i >= 0; i--) {
      if ((value >> i) & 1 == 1) _out[_bit >> 3] |= 0x80 >> (_bit & 7);
      _bit++;
    }
  }

  Uint8List bytes() => Uint8List.sublistView(_out, 0, (_bit + 7) >> 3);
}

/// Seconds since 1900 in 32.32 fixed point.
int _ntpNow() {
  final us = DateTime.now().microsecondsSinceEpoch;
  final seconds = us ~/ 1000000 + 2208988800;
  final fraction = ((us % 1000000) << 32) ~/ 1000000;
  return (seconds << 32) | fraction;
}

void _putNtp(ByteData b, int at, int ntp) {
  b.setUint32(at, (ntp >> 32) & 0xFFFFFFFF);
  b.setUint32(at + 4, ntp & 0xFFFFFFFF);
}

/// The AirPort Express public key (its private half is what every RAOP
/// receiver uses to read the AES key).
final _rsaModulus = BigInt.parse(
  base64
      .decode(
        '59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUtwC5vOYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6'
        'DZHJ2YCCLlDRKSKv6kDqnw4UwPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuBOitnZ/bDzPHrTOZz0Dew0uowxf/+sG+NCK3eQJ'
        'VxqcaJ/vEHKIVd2M+5qL71yJQ+87X6oV3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/UAaHqn9JdsBWLUEpVviYnhimNVvYFZeCXg/IdTQ+x4IRdiXN'
        'v5hEew==',
      )
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(),
  radix: 16,
);

/// RSA-OAEP (SHA-1) encryption of [message] with the AirPort key.
Uint8List _rsaOaep(Uint8List message, math.Random random) {
  const k = 256, hLen = 20;
  final lHash = sha1.convert(const []).bytes;
  final db = Uint8List(k - hLen - 1)
    ..setRange(0, hLen, lHash)
    ..[k - hLen - 1 - message.length - 1] = 1
    ..setRange(k - hLen - 1 - message.length, k - hLen - 1, message);
  final seed = Uint8List.fromList(List.generate(hLen, (_) => random.nextInt(256)));
  Uint8List mgf1(Uint8List seed, int length) {
    final out = BytesBuilder();
    for (var c = 0; out.length < length; c++) {
      out.add(sha1.convert([...seed, (c >> 24) & 0xFF, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF]).bytes);
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }

  final dbMask = mgf1(seed, db.length);
  for (var i = 0; i < db.length; i++) {
    db[i] ^= dbMask[i];
  }
  final seedMask = mgf1(db, hLen);
  for (var i = 0; i < hLen; i++) {
    seed[i] ^= seedMask[i];
  }
  final em = Uint8List.fromList([0, ...seed, ...db]);
  final m = BigInt.parse(em.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), radix: 16);
  final c = m.modPow(BigInt.from(65537), _rsaModulus).toRadixString(16).padLeft(k * 2, '0');
  return Uint8List.fromList([for (var i = 0; i < k; i++) int.parse(c.substring(i * 2, i * 2 + 2), radix: 16)]);
}

/// Where a song's audio comes from: an FFmpeg input (a path or `pipe:0`
/// fed by [stdin]), and how far in to start.
class AirPlaySource {
  const AirPlaySource({required this.input, this.stdin, this.start = Duration.zero, this.end});

  final String input;
  final Stream<List<int>> Function()? stdin;
  final Duration start;
  final Duration? end;
}

/// One connection to a speaker, streaming songs to it.
///
/// AirPlay 1 has the sender keep time: audio goes out at its real pace over
/// UDP, a sync packet each second says which sample is due when, and the
/// speaker plays [latencyFrames] behind (2 s). Pausing and seeking flush its
/// buffer and start the audio again from the new place.
class AirPlaySession {
  AirPlaySession(this.device, {this.onEnded, this.onError, this.latencyFrames = 88200});

  final AirPlayDevice device;
  final VoidCallback? onEnded;
  final void Function(String message)? onError;
  final int latencyFrames;

  static const _framesPerPacket = 352;
  static const _rate = 44100;

  final _random = math.Random.secure();
  late final int _ssrc = _random.nextInt(1 << 31);
  late final String _session = '${_random.nextInt(1 << 31)}';
  late final String _dacp = List.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Socket? _rtsp;
  final _rtspReplies = StreamController<_RtspReply>.broadcast();
  final _rtspBuffer = BytesBuilder();
  int _cseq = 0;
  String? _sessionId;

  RawDatagramSocket? _audio, _control, _timing;
  int _serverAudioPort = 0, _serverControlPort = 0;

  Uint8List? _aesKey, _aesIv;

  int _seq = 0;
  int _rtptime = 0;

  /// Recently sent packets, for the speaker's resend requests.
  final _sent = <int, Uint8List>{};

  // ── Connecting ─────────────────────────────────────────────────────────

  Future<void> connect() async {
    final s = await Socket.connect(device.host, device.port, timeout: const Duration(seconds: 5));
    _rtsp = s;
    s.listen(
      _onRtspData,
      onError: (Object e) => _fail('Lost connection to ${device.name}'),
      onDone: () {
        if (_rtsp != null) _fail('${device.name} hung up');
      },
    );
    final local = s.address;
    _audio = await RawDatagramSocket.bind(local, 0);
    _control = await RawDatagramSocket.bind(local, 0)
      ..listen((_) => _onControl());
    _timing = await RawDatagramSocket.bind(local, 0)
      ..listen((_) => _onTiming());

    _seq = _random.nextInt(0xFFFF);
    _rtptime = _random.nextInt(1 << 31);
    if (!device.encryptions.contains(0)) {
      _aesKey = Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
      _aesIv = Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
    }

    await _request('OPTIONS', '*');
    final uri = 'rtsp://${local.address}/$_session';
    final sdp = StringBuffer()
      ..write('v=0\r\n')
      ..write('o=iTunes $_session 0 IN IP4 ${local.address}\r\n')
      ..write('s=iTunes\r\n')
      ..write('c=IN IP4 ${device.host.address}\r\n')
      ..write('t=0 0\r\n')
      ..write('m=audio 0 RTP/AVP 96\r\n')
      ..write('a=rtpmap:96 AppleLossless\r\n')
      ..write('a=fmtp:96 $_framesPerPacket 0 16 40 10 14 2 255 0 0 $_rate\r\n');
    if (_aesKey != null) {
      String b64(List<int> b) => base64.encode(b).replaceAll('=', '');
      sdp
        ..write('a=rsaaeskey:${b64(_rsaOaep(_aesKey!, _random))}\r\n')
        ..write('a=aesiv:${b64(_aesIv!)}\r\n');
    }
    await _request('ANNOUNCE', uri, headers: {'Content-Type': 'application/sdp'}, body: utf8.encode('$sdp'));
    final setup = await _request(
      'SETUP',
      uri,
      headers: {
        'Transport':
            'RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;'
            'control_port=${_control!.port};timing_port=${_timing!.port}',
      },
    );
    final transport = setup.headers['transport'] ?? '';
    int port(String key) => int.tryParse(RegExp('$key=(\\d+)').firstMatch(transport)?.group(1) ?? '') ?? 0;
    _serverAudioPort = port('server_port');
    _serverControlPort = port('control_port');
    _sessionId = setup.headers['session']?.split(';').first;
    if (_serverAudioPort == 0) throw StateError('${device.name} gave no audio port');
    await _request('RECORD', uri, headers: {'Range': 'npt=0-', 'RTP-Info': 'seq=$_seq;rtptime=$_rtptime'});
    _uri = uri;
  }

  String? _uri;

  Future<_RtspReply> _request(
    String method,
    String uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final s = _rtsp;
    if (s == null) throw StateError('not connected');
    final cseq = ++_cseq;
    final head = StringBuffer('$method $uri RTSP/1.0\r\nCSeq: $cseq\r\n')
      ..write('User-Agent: iTunes/11.0.4 (Windows; N)\r\n')
      ..write('Client-Instance: $_dacp\r\nDACP-ID: $_dacp\r\nActive-Remote: ${_ssrc & 0x7FFFFFFF}\r\n');
    if (_sessionId != null) head.write('Session: $_sessionId\r\n');
    headers.forEach((k, v) => head.write('$k: $v\r\n'));
    if (body != null) head.write('Content-Length: ${body.length}\r\n');
    head.write('\r\n');
    final reply = _rtspReplies.stream.firstWhere((r) => r.cseq == cseq).timeout(const Duration(seconds: 6));
    s.add([...ascii.encode('$head'), ...?body]);
    final r = await reply;
    if (r.status != 200) throw StateError('${device.name} answered $method with ${r.status}');
    return r;
  }

  void _onRtspData(Uint8List data) {
    _rtspBuffer.add(data);
    while (true) {
      final bytes = _rtspBuffer.toBytes();
      final text = latin1.decode(bytes);
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      final lines = text.substring(0, end).split('\r\n');
      final headers = <String, String>{};
      for (final l in lines.skip(1)) {
        final c = l.indexOf(':');
        if (c > 0) headers[l.substring(0, c).trim().toLowerCase()] = l.substring(c + 1).trim();
      }
      final length = int.tryParse(headers['content-length'] ?? '') ?? 0;
      if (bytes.length < end + 4 + length) return;
      _rtspBuffer
        ..clear()
        ..add(bytes.sublist(end + 4 + length));
      _rtspReplies.add(
        _RtspReply(
          int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '') ?? 0,
          int.tryParse(headers['cseq'] ?? '') ?? -1,
          headers,
        ),
      );
    }
  }

  // ── Timing, control ────────────────────────────────────────────────────

  void _onTiming() {
    final t = _timing;
    final d = t?.receive();
    if (t == null || d == null || d.data.length < 32 || d.data[1] & 0x7F != 0x52) return;
    final now = _ntpNow();
    final reply = ByteData(32)
      ..setUint8(0, 0x80)
      ..setUint8(1, 0xD3)
      ..setUint16(2, 7);
    // Origin: the request's transmit time.
    for (var i = 0; i < 8; i++) {
      reply.setUint8(8 + i, d.data[24 + i]);
    }
    _putNtp(reply, 16, now);
    _putNtp(reply, 24, _ntpNow());
    t.send(reply.buffer.asUint8List(), d.address, d.port);
  }

  void _onControl() {
    final c = _control;
    final d = c?.receive();
    if (c == null || d == null || d.data.length < 8 || d.data[1] & 0x7F != 0x55) return;
    final v = ByteData.sublistView(d.data);
    final first = v.getUint16(4), count = v.getUint16(6);
    for (var i = 0; i < count; i++) {
      final p = _sent[(first + i) & 0xFFFF];
      if (p != null) c.send([0x80, 0xD6, 0x00, 0x01, ...p], device.host, _serverControlPort);
    }
  }

  bool _firstSync = true;

  /// [head]: the RTP time of the audio going out now.
  void _sendSync(int head) {
    final c = _control;
    if (c == null || _serverControlPort == 0) return;
    final b = ByteData(20)
      ..setUint8(0, _firstSync ? 0x90 : 0x80)
      ..setUint8(1, 0xD4)
      ..setUint16(2, 7)
      ..setUint32(4, (head - latencyFrames) & 0xFFFFFFFF);
    _putNtp(b, 8, _ntpNow());
    b.setUint32(16, head & 0xFFFFFFFF);
    _firstSync = false;
    c.send(b.buffer.asUint8List(), device.host, _serverControlPort);
  }

  // ── Streaming ──────────────────────────────────────────────────────────

  AirPlaySource? _source;
  Duration? _duration;
  Process? _ffmpeg;
  int _generation = 0;

  bool _playing = false;
  bool get playing => _playing;

  /// Where the audio being sent started (in the song), and when.
  Duration _from = Duration.zero;
  DateTime? _startedAt;
  Duration _pausedAt = Duration.zero;

  /// What the speaker is playing now (it plays [latencyFrames] behind).
  Duration get position {
    final started = _startedAt;
    if (!_playing || started == null) return _pausedAt;
    final heard = DateTime.now().difference(started) - Duration(microseconds: latencyFrames * 1000000 ~/ _rate);
    final p = _from + (heard.isNegative ? Duration.zero : heard);
    final d = _duration;
    return d != null && p > d ? d : p;
  }

  /// Plays [source] from [from] (or holds it there when not [play]).
  Future<void> load(AirPlaySource source, {Duration? duration, Duration from = Duration.zero, bool play = true}) async {
    _source = source;
    _duration = duration;
    await _flush();
    _pausedAt = from;
    if (play) _start(from);
  }

  Future<void> play() async {
    if (_playing || _source == null) return;
    _start(_pausedAt);
  }

  Future<void> pause() async {
    if (!_playing) return;
    _pausedAt = position;
    await _flush();
  }

  Future<void> seek(Duration to) async {
    final wasPlaying = _playing;
    await _flush();
    _pausedAt = to;
    if (wasPlaying) _start(to);
  }

  /// 0..1.
  Future<void> setVolume(double v) async {
    final db = v <= 0.001 ? -144.0 : -30 + 30 * v.clamp(0.0, 1.0);
    await _guard(
      () => _request(
        'SET_PARAMETER',
        _uri!,
        headers: {'Content-Type': 'text/parameters'},
        body: ascii.encode('volume: ${db.toStringAsFixed(6)}\r\n'),
      ),
    );
  }

  /// Title, artist and album for the speaker's display (DMAP).
  Future<void> setMetadata({required String title, String? artist, String? album}) async {
    List<int> item(String code, String value) {
      final v = utf8.encode(value);
      return [...ascii.encode(code), ...(ByteData(4)..setUint32(0, v.length)).buffer.asUint8List(), ...v];
    }

    final items = [
      ...item('minm', title),
      if (artist != null) ...item('asar', artist),
      if (album != null) ...item('asal', album),
    ];
    final body = [...ascii.encode('mlit'), ...(ByteData(4)..setUint32(0, items.length)).buffer.asUint8List(), ...items];
    await _guard(
      () => _request(
        'SET_PARAMETER',
        _uri!,
        headers: {'Content-Type': 'application/x-dmap-tagged', 'RTP-Info': 'rtptime=$_rtptime'},
        body: body,
      ),
    );
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_uri == null) return;
    try {
      await action();
    } catch (e) {
      debugPrint('AirPlay: $e');
    }
  }

  /// Stops sending and drops what the speaker has buffered.
  Future<void> _flush() async {
    _generation++;
    _playing = false;
    _ffmpeg?.kill();
    _ffmpeg = null;
    if (_uri != null) {
      await _guard(() => _request('FLUSH', _uri!, headers: {'RTP-Info': 'seq=$_seq;rtptime=$_rtptime'}));
    }
  }

  void _start(Duration from) {
    final source = _source;
    if (source == null) return;
    final generation = ++_generation;
    _from = from;
    _playing = true;
    _firstSync = true;
    _stream(source, from, generation).catchError((Object e) {
      if (generation == _generation) _fail('Couldn\'t play on ${device.name}: $e');
    });
  }

  Future<void> _stream(AirPlaySource source, Duration from, int generation) async {
    final start = source.start + from;
    final ffmpeg = await Process.start('ffmpeg', [
      '-hide_banner', '-loglevel', 'error', //
      if (start > Duration.zero) ...['-ss', '${start.inMilliseconds / 1000}'],
      '-i', source.input,
      if (source.end != null) ...['-t', '${(source.end! - start).inMilliseconds / 1000}'],
      '-map', '0:a:0', '-f', 's16le', '-ar', '$_rate', '-ac', '2', 'pipe:1',
    ]);
    if (generation != _generation) {
      ffmpeg.kill();
      return;
    }
    _ffmpeg = ffmpeg;
    ffmpeg.stderr.drain<void>().ignore();
    if (source.stdin case final input?) {
      ffmpeg.stdin.addStream(input()).then((_) => ffmpeg.stdin.close(), onError: (Object _) {}).ignore();
    }

    const packetBytes = _framesPerPacket * 4;
    final pending = BytesBuilder(copy: false);
    final clock = Stopwatch()..start();
    _startedAt = DateTime.now();
    final firstRtp = _rtptime;
    var frames = 0;
    var lastSync = -1;
    var first = true;

    Future<void> send(Uint8List pcm) async {
      if (generation != _generation) return;
      // Real pace: packet n leaves when its audio is due (the speaker buffers the latency).
      final due = Duration(microseconds: frames * 1000000 ~/ _rate);
      final wait = due - clock.elapsed;
      if (wait > const Duration(milliseconds: 2)) await Future<void>.delayed(wait);
      if (generation != _generation) return;
      final second = clock.elapsed.inSeconds;
      if (second != lastSync) {
        lastSync = second;
        _sendSync(firstRtp + (clock.elapsed.inMicroseconds * _rate ~/ 1000000));
      }
      _sendAudio(pcm, first);
      first = false;
      frames += pcm.length ~/ 4;
    }

    await for (final chunk in ffmpeg.stdout) {
      if (generation != _generation) return;
      pending.add(chunk);
      while (pending.length >= packetBytes) {
        final all = pending.takeBytes();
        await send(Uint8List.sublistView(all, 0, packetBytes));
        pending.add(Uint8List.sublistView(all, packetBytes));
        if (generation != _generation) return;
      }
    }
    if (generation != _generation) return;
    if (pending.length >= 4) {
      final rest = pending.takeBytes();
      final padded = Uint8List(packetBytes)..setRange(0, rest.length - rest.length % 4, rest);
      await send(padded);
    }
    // The speaker is still playing its buffer.
    await Future<void>.delayed(Duration(microseconds: latencyFrames * 1000000 ~/ _rate));
    if (generation != _generation) return;
    _playing = false;
    _pausedAt = _duration ?? position;
    onEnded?.call();
  }

  void _sendAudio(Uint8List pcm, bool first) {
    final a = _audio;
    if (a == null) return;
    final payload = alacFrame(pcm);
    if (_aesKey != null) _encrypt(payload);
    final packet = Uint8List(12 + payload.length);
    ByteData.sublistView(packet)
      ..setUint8(0, 0x80)
      ..setUint8(1, first ? 0xE0 : 0x60)
      ..setUint16(2, _seq)
      ..setUint32(4, _rtptime & 0xFFFFFFFF)
      ..setUint32(8, _ssrc);
    packet.setRange(12, packet.length, payload);
    a.send(packet, device.host, _serverAudioPort);
    _sent[_seq] = packet;
    _sent.remove((_seq - 512) & 0xFFFF);
    _seq = (_seq + 1) & 0xFFFF;
    _rtptime = (_rtptime + _framesPerPacket) & 0xFFFFFFFF;
  }

  /// AES-128-CBC over the whole 16-byte blocks, the IV fresh for each packet.
  void _encrypt(Uint8List payload) {
    final cipher = CBCBlockCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(_aesKey!), _aesIv!));
    for (var o = 0; o + 16 <= payload.length; o += 16) {
      cipher.processBlock(payload, o, payload, o);
    }
  }

  void _fail(String message) {
    if (_closed) return;
    onError?.call(message);
    close();
  }

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _playing = false;
    _ffmpeg?.kill();
    if (_uri != null && _rtsp != null) {
      try {
        await _request('TEARDOWN', _uri!).timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    final s = _rtsp;
    _rtsp = null;
    s?.destroy();
    _audio?.close();
    _control?.close();
    _timing?.close();
    await _rtspReplies.close();
  }
}

class _RtspReply {
  const _RtspReply(this.status, this.cseq, this.headers);
  final int status;
  final int cseq;
  final Map<String, String> headers;
}
