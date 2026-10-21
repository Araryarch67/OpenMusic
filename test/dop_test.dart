// StreamAudioSource is just_audio's documented byte-stream API.
// ignore_for_file: experimental_member_use

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/services/dop.dart';

/// Channel [c]'s [i]-th DSD byte in the test files, MSB-first.
int _byte(int c, int i) => (i * 31 + c * 101 + (i >> 8)) & 0xFF;

int _reverse(int b) {
  var r = 0;
  for (var i = 0; i < 8; i++) {
    r = (r << 1) | ((b >> i) & 1);
  }
  return r;
}

/// A DSF (LSB-first, 4096-byte blocks) with [bytes] per channel.
void _writeDsf(String path, {int channels = 2, int bytes = 10000, int rate = 2822400}) {
  const bs = 4096;
  final blocks = (bytes + bs - 1) ~/ bs;
  final data = Uint8List(blocks * bs * channels);
  for (var k = 0; k < blocks; k++) {
    for (var c = 0; c < channels; c++) {
      for (var j = 0; j < bs; j++) {
        final i = k * bs + j;
        // Padding past the end is zeros, as real files have.
        data[(k * channels + c) * bs + j] = i < bytes ? _reverse(_byte(c, i)) : 0;
      }
    }
  }
  final h = ByteData(28 + 52 + 12);
  void tag(int at, String s) => h.buffer.asUint8List().setAll(at, ascii.encode(s));
  tag(0, 'DSD ');
  h.setUint64(4, 28, Endian.little);
  h.setUint64(12, 28 + 52 + 12 + data.length, Endian.little);
  tag(28, 'fmt ');
  h.setUint64(32, 52, Endian.little);
  h.setUint32(40, 1, Endian.little); // version
  h.setUint32(44, 0, Endian.little); // raw DSD
  h.setUint32(48, 2, Endian.little); // stereo
  h.setUint32(52, channels, Endian.little);
  h.setUint32(56, rate, Endian.little);
  h.setUint32(60, 1, Endian.little); // LSB first
  h.setUint64(64, bytes * 8, Endian.little);
  h.setUint32(72, bs, Endian.little);
  tag(80, 'data');
  h.setUint64(84, 12 + data.length, Endian.little);
  File(path).writeAsBytesSync([...h.buffer.asUint8List(), ...data]);
}

/// A DSDIFF (byte-interleaved, MSB-first) with [bytes] per channel.
void _writeDff(String path, {int channels = 2, int bytes = 10000, int rate = 5644800, bool dst = false}) {
  final out = BytesBuilder();
  void id(String s) => out.add(ascii.encode(s));
  void u64(int v) => out.add((ByteData(8)..setUint64(0, v)).buffer.asUint8List());
  final body = BytesBuilder();
  final prop = BytesBuilder()
    ..add(ascii.encode('SND '))
    ..add(ascii.encode('FS  '))
    ..add((ByteData(8)..setUint64(0, 4)).buffer.asUint8List())
    ..add((ByteData(4)..setUint32(0, rate)).buffer.asUint8List())
    ..add(ascii.encode('CHNL'))
    ..add((ByteData(8)..setUint64(0, 2 + 4 * channels)).buffer.asUint8List())
    ..add((ByteData(2)..setUint16(0, channels)).buffer.asUint8List())
    ..add(ascii.encode(List.filled(channels, 'SLFT').join()))
    ..add(ascii.encode('CMPR'))
    ..add((ByteData(8)..setUint64(0, 4)).buffer.asUint8List())
    ..add(ascii.encode(dst ? 'DST ' : 'DSD '));
  final propBytes = prop.takeBytes();
  body
    ..add(ascii.encode('FVER'))
    ..add((ByteData(8)..setUint64(0, 4)).buffer.asUint8List())
    ..add((ByteData(4)..setUint32(0, 0x01050000)).buffer.asUint8List())
    ..add(ascii.encode('PROP'))
    ..add((ByteData(8)..setUint64(0, propBytes.length)).buffer.asUint8List())
    ..add(propBytes)
    ..add(ascii.encode('DSD '))
    ..add((ByteData(8)..setUint64(0, bytes * channels)).buffer.asUint8List())
    ..add([
      for (var i = 0; i < bytes; i++)
        for (var c = 0; c < channels; c++) _byte(c, i),
    ]);
  final b = body.takeBytes();
  id('FRM8');
  u64(4 + b.length);
  id('DSD ');
  out.add(b);
  File(path).writeAsBytesSync(out.takeBytes());
}

Future<Uint8List> _all(DopAudioSource s) async {
  final out = BytesBuilder();
  await for (final b in s.bytes(0, s.length)) {
    out.add(b);
  }
  return out.takeBytes();
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dop'));
  tearDown(() => dir.deleteSync(recursive: true));

  for (final kind in ['dsf', 'dff']) {
    test('$kind: every DSD byte lands in a DoP frame under alternating markers', () async {
      final path = '${dir.path}/song.$kind';
      kind == 'dsf' ? _writeDsf(path) : _writeDff(path);
      final dsd = DsdFile.read(path)!;
      expect(dsd.channels, 2);
      expect(dsd.bytesPerChannel, 10000);
      expect(dsd.frames, 5000);
      expect(dsd.multiple, kind == 'dsf' ? 64 : 128);
      expect(dsd.dopRate, kind == 'dsf' ? 176400 : 352800);

      final source = DopAudioSource(dsd);
      final wav = await _all(source);
      expect(wav.length, source.length);
      expect(wav.length, DopAudioSource.headerSize + 5000 * 2 * 3);
      for (var f = 0; f < dsd.frames; f++) {
        for (var c = 0; c < 2; c++) {
          final o = DopAudioSource.headerSize + (f * 2 + c) * 3;
          // Little-endian 24-bit: newer byte, older byte, marker.
          expect(wav[o + 2], f.isEven ? 0x05 : 0xFA, reason: 'marker of frame $f');
          expect(wav[o + 1], _byte(c, f * 2), reason: 'frame $f ch $c first byte');
          expect(wav[o], _byte(c, f * 2 + 1), reason: 'frame $f ch $c second byte');
        }
      }
    });
  }

  test('any byte range is the same bytes as the whole stream (seeking)', () async {
    final path = '${dir.path}/song.dsf';
    _writeDsf(path, bytes: 20000);
    final source = DopAudioSource(DsdFile.read(path)!);
    final whole = await _all(source);
    final random = math.Random(1);
    for (var i = 0; i < 40; i++) {
      final a = random.nextInt(whole.length);
      final b = a + random.nextInt(whole.length - a + 1);
      final r = await source.request(a, b);
      final got = BytesBuilder();
      await for (final chunk in r.stream) {
        got.add(chunk);
      }
      expect(got.takeBytes(), whole.sublist(a, b), reason: 'bytes $a-$b');
      expect(r.sourceLength, whole.length);
    }
  });

  test('the WAV is 24-bit PCM at the DoP rate to FFmpeg (what mpv sees)', () async {
    final path = '${dir.path}/song.dsf';
    _writeDsf(path, bytes: 352800 * 2); // 2 s of DSD64 (2.8224 Mbit/s = 352800 bytes/s)
    final source = DopAudioSource(DsdFile.read(path)!);
    final wav = File('${dir.path}/dop.wav')..writeAsBytesSync(await _all(source));
    final r = await Process.run('ffprobe', [
      '-v', 'error', '-show_entries', 'stream=codec_name,sample_rate,channels,bits_per_sample:format=duration', //
      '-of', 'json', wav.path,
    ]);
    if (r.exitCode != 0 && (r.stderr as String).contains('not found')) return markTestSkipped('no ffprobe');
    final j = jsonDecode(r.stdout as String) as Map;
    final s = (j['streams'] as List).single as Map;
    expect(s['codec_name'], 'pcm_s24le');
    expect(s['sample_rate'], '176400');
    expect(s['channels'], 2);
    expect(double.parse((j['format'] as Map)['duration'] as String), closeTo(2, 0.01));
  });

  test('compressed DSDIFF (DST) and other files are not DoP material', () {
    final dst = '${dir.path}/dst.dff';
    _writeDff(dst, dst: true);
    expect(DsdFile.read(dst), isNull);
    final junk = File('${dir.path}/x.dsf')..writeAsStringSync('not dsd');
    expect(DsdFile.read(junk.path), isNull);
    expect(DsdFile.isDsdPath('/a/b.DSF'), isTrue);
    expect(DsdFile.isDsdPath('/a/b.flac'), isFalse);
  });
}
