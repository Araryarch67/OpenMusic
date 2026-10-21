import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/services/airplay.dart';

/// A shairport-sync built for classic AirPlay (`--without-airplay-2`, with
/// `--with-tinysvcmdns` and `--with-stdout`): the speaker these tests send to.
/// They are skipped without it.
final _shairport = Platform.environment['SHAIRPORT'];

void main() {
  test('ALAC frames carry the samples as they are', () {
    final pcm = Uint8List.fromList(List.generate(352 * 4, (i) => (i * 37) & 0xFF));
    final frame = alacFrame(pcm);
    // Header: 3+4+12+1+2+1 bits, then the 32-bit sample count.
    expect(frame[0] >> 5, 1, reason: 'channel pair');
    expect(frame.length, ((3 + 4 + 12 + 1 + 2 + 1 + 32 + 352 * 32 + 3) + 7) ~/ 8);
    // The first left sample starts 55 bits in: big-endian, shifted by 7 bits.
    final bits = BigInt.parse(frame.sublist(6, 10).map((b) => b.toRadixString(2).padLeft(8, '0')).join(), radix: 2);
    final firstLeft = (bits >> (32 - 7 - 16)).toInt() & 0xFFFF;
    expect(firstLeft, pcm[0] | pcm[1] << 8);
  });

  test('mDNS records become a device', () {
    final d = AirPlay.fromRecords('D493905D42EF@Kitchen._raop._tcp.local', InternetAddress('10.0.0.9'), 5000, [
      'txtvers=1\ncn=0,1\net=0,1\ntp=UDP',
    ])!;
    expect(d.name, 'Kitchen');
    expect(d.encryptions, {0, 1});
    expect(d.usable, isTrue);
    final fairPlayOnly = AirPlay.fromRecords('X@TV._raop._tcp.local', InternetAddress('10.0.0.8'), 7000, [
      'et=3,4\ncn=1',
    ]);
    expect(fairPlayOnly!.usable, isFalse);
  });

  group('to a real receiver (shairport-sync)', () {
    late Directory dir;
    late Process speaker;
    late String raw;
    var port = 5300;

    setUp(() async {
      if (_shairport == null) return;
      dir = Directory.systemTemp.createTempSync('airplay');
      raw = '${dir.path}/received.raw';
      port++;
      File('${dir.path}/sps.conf').writeAsStringSync('''
general = { name = "Test Speaker $port"; port = $port; mdns_backend = "tinysvcmdns"; ignore_volume_control = "yes"; interpolation = "basic"; };
''');
      speaker = await Process.start('sh', [
        '-c',
        'exec "$_shairport" -c sps.conf -o stdout > "$raw"',
      ], workingDirectory: dir.path);
      speaker.stderr.drain<void>().ignore();
      // It checks its resampler for a moment before listening.
      for (var i = 0; i < 40; i++) {
        try {
          (await Socket.connect(InternetAddress.loopbackIPv4, port)).destroy();
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      fail('shairport-sync did not start');
    });

    tearDown(() async {
      if (_shairport == null) return;
      speaker.kill();
      await speaker.exitCode;
      dir.deleteSync(recursive: true);
    });

    test('finds it over mDNS', () async {
      if (_shairport == null) return markTestSkipped('set SHAIRPORT to a classic shairport-sync');
      final found = await AirPlay.discover(timeout: const Duration(seconds: 3)).toList();
      final mine = found.where((d) => d.name == 'Test Speaker $port');
      expect(mine, isNotEmpty, reason: 'found: $found');
      expect(mine.first.port, port);
      expect(mine.first.encryptions, containsAll([0, 1]));
    });

    for (final encrypted in [false, true]) {
      test('plays a song to the end, sample for sample${encrypted ? ' (RSA + AES)' : ''}', () async {
        if (_shairport == null) return markTestSkipped('set SHAIRPORT to a classic shairport-sync');
        // 3 s of a 1 kHz tone, louder on the left, as 16-bit stereo.
        final wav = '${dir.path}/tone.wav';
        final made = await Process.run('ffmpeg', [
          '-v', 'error', '-f', 'lavfi', '-i', 'sine=f=1000:d=3:sample_rate=44100', //
          '-af', 'pan=stereo|c0=0.9*c0|c1=0.4*c0', '-c:a', 'pcm_s16le', wav,
        ]);
        expect(made.exitCode, 0);
        final device = AirPlayDevice(
          name: 'Test Speaker',
          host: InternetAddress.loopbackIPv4,
          port: port,
          encryptions: encrypted ? {1} : {0, 1},
        );
        final ended = Completer<void>();
        final errors = <String>[];
        final session = AirPlaySession(device, onEnded: ended.complete, onError: errors.add, latencyFrames: 22050);
        await session.connect();
        await session.setMetadata(title: 'Tone', artist: 'Test');
        await session.load(
          const AirPlaySource(input: 'pipe:0').copyWithPath(wav),
          duration: const Duration(seconds: 3),
        );
        expect(session.playing, isTrue);
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(session.position.inMilliseconds, inInclusiveRange(300, 900), reason: 'plays 0.5 s behind');
        await ended.future.timeout(const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await session.close();
        expect(errors, isEmpty);

        final want = _pcm(File(wav).readAsBytesSync());
        final got = File(raw).readAsBytesSync().buffer.asInt16List();
        // Find where the tone starts in what the speaker played, then compare.
        final start = got.indexWhere((s) => s != 0);
        expect(start, greaterThanOrEqualTo(0), reason: 'the speaker played something');
        final firstWant = want.indexWhere((s) => s != 0);
        final n = want.length - firstWant;
        expect(got.length - start, greaterThanOrEqualTo(n - 352 * 2), reason: 'all of it arrived');
        var differ = 0;
        for (var i = 0; i < n && start + i < got.length; i++) {
          if (got[start + i] != want[firstWant + i]) differ++;
        }
        expect(differ, lessThan(n ~/ 1000), reason: '$differ of $n samples differ');
      });
    }
  });
}

extension on AirPlaySource {
  AirPlaySource copyWithPath(String path) => AirPlaySource(input: path, start: start, end: end);
}

/// The samples of a 16-bit WAV.
Int16List _pcm(Uint8List wav) {
  final v = ByteData.sublistView(wav);
  var at = 12;
  while (at + 8 <= wav.length) {
    final id = String.fromCharCodes(wav.sublist(at, at + 4));
    final size = v.getUint32(at + 4, Endian.little);
    if (id == 'data') return Uint8List.fromList(wav.sublist(at + 8, at + 8 + size)).buffer.asInt16List();
    at += 8 + size + (size & 1);
  }
  throw StateError('no data');
}
