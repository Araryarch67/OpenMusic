// StreamAudioSource is just_audio's documented byte-stream API.
// ignore_for_file: experimental_member_use

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/services/dop.dart';
import 'package:openmusic/services/sacd.dart';

import 'support/sacd_iso_writer.dart';

/// The independent decoder to check images against (github.com/Sound-Linux-More/sacd);
/// those checks are skipped without it.
final _reference = Platform.environment['SACD_REFERENCE'];

Future<Uint8List> _collect(Stream<Uint8List> s) async {
  final b = BytesBuilder();
  await for (final x in s) {
    b.add(x);
  }
  return b.takeBytes();
}

/// 16-bit mono PCM of [input] (any format FFmpeg reads) at [rate].
Future<Int16List?> _decode(String input, {int rate = 44100, int channel = 0}) async {
  final r = await Process.run('ffmpeg', [
    '-v', 'error', '-i', input, '-af', 'pan=mono|c0=c$channel', '-ar', '$rate', '-f', 's16le', '-', //
  ], stdoutEncoding: null);
  if (r.exitCode != 0) return null;
  final bytes = Uint8List.fromList(r.stdout as List<int>);
  return bytes.buffer.asInt16List(0, bytes.length ~/ 2);
}

/// Strongest frequency near [around], by counting zero crossings.
double _frequency(Int16List pcm, int rate) {
  var crossings = 0;
  for (var i = 1; i < pcm.length; i++) {
    if ((pcm[i - 1] < 0) != (pcm[i] < 0)) crossings++;
  }
  return crossings / 2 / (pcm.length / rate);
}

void main() {
  late Directory dir;
  late List<Uint8List> one, two;
  setUpAll(() {
    one = dsdSineFrames(seconds: 1, hz: 1000);
    two = dsdSineFrames(seconds: 0.6, hz: 500);
  });
  setUp(() => dir = Directory.systemTemp.createTempSync('sacd'));
  tearDown(() => dir.deleteSync(recursive: true));

  String stereoIso() {
    final path = '${dir.path}/album.iso';
    writeSacdIso(
      path,
      album: 'Test Album',
      artist: 'Test Artist',
      areas: [
        IsoArea(
          channels: 2,
          dst: false,
          tracks: [IsoTrack('First Song', 'Singer A', one), IsoTrack('Second Song', 'Singer B', two)],
        ),
      ],
    );
    return path;
  }

  test('reads the album, its songs and their places on the disc', () {
    final disc = SacdDisc.read(stereoIso())!;
    expect(disc.albumTitle, 'Test Album');
    expect(disc.albumArtist, 'Test Artist');
    expect(disc.area.channels, 2);
    expect(disc.area.dst, isFalse);
    final t = disc.area.tracks;
    expect(t.map((x) => x.title), ['First Song', 'Second Song']);
    expect(t.map((x) => x.performer), ['Singer A', 'Singer B']);
    expect(t.map((x) => x.frames), [75, 45]);
    expect(t[1].startFrame, 75);
    final tracks = disc.tracks();
    expect(tracks.first.id, endsWith('album.iso#sacd1'));
    expect(tracks.first.duration, const Duration(seconds: 1));
    expect(SacdDisc.isSacdTrack(tracks.last), isTrue);
    expect(SacdDisc.find(tracks.last)!.$2.title, 'Second Song');

    final notSacd = File('${dir.path}/data.iso')..writeAsBytesSync(Uint8List(2048 * 600));
    expect(SacdDisc.read(notSacd.path), isNull);
  });

  test('frames come back exactly, from any starting frame (seeking)', () async {
    final disc = SacdDisc.read(stereoIso())!;
    final second = SacdFrameReader(disc, disc.area.tracks[1]);
    final all = await second.frames(0, 1000).toList();
    expect(all.length, two.length);
    for (var i = 0; i < two.length; i++) {
      expect(all[i], two[i], reason: 'frame $i');
    }
    final first = SacdFrameReader(disc, disc.area.tracks[0]);
    for (final from in [0, 1, 37, 74]) {
      final got = await first.frames(from, 3).toList();
      expect(got.length, math.min(3, 75 - from));
      expect(got.first, one[from], reason: 'seek to frame $from');
    }
  });

  test('plays as a DSDIFF that FFmpeg decodes, seekable by byte', () async {
    final disc = SacdDisc.read(stereoIso())!;
    final source = SacdAudioSource(disc, disc.area.tracks[0]);
    final dff = File('${dir.path}/virtual.dff')..writeAsBytesSync(await _collect(source.bytes(0, source.length)));
    expect(dff.lengthSync(), source.length);
    // The audio in it is the song's DSD, byte for byte.
    final body = dff.readAsBytesSync().sublist(dff.lengthSync() - 75 * 9408);
    expect(body, [for (final f in one) ...f]);
    // A range is the same bytes as the whole (what the player asks for when seeking).
    final whole = dff.readAsBytesSync();
    for (final (a, b) in [(0, 10), (50, 20000), (100000, 400000), (whole.length - 5, whole.length)]) {
      expect(await _collect(source.bytes(a, b)), whole.sublist(a, b), reason: 'bytes $a-$b');
    }
    final pcm = await _decode(dff.path);
    if (pcm == null) return markTestSkipped('ffmpeg not available');
    expect(pcm.length / 44100, closeTo(1, 0.02));
    expect(_frequency(pcm.sublist(4410), 44100), closeTo(1000, 15));
    final right = (await _decode(dff.path, channel: 1))!;
    expect(_frequency(right.sublist(4410), 44100), closeTo(2000, 30));
  });

  test('DoP from an SACD song carries its DSD under markers', () async {
    final disc = SacdDisc.read(stereoIso())!;
    final dsd = SacdDsd(disc, disc.area.tracks[1]);
    expect(dsd.bytesPerChannel, 45 * 4704);
    // Across a frame boundary.
    final bytes = await dsd.interleaved(4700, 10);
    final flat = [for (final f in two) ...f];
    expect(bytes, flat.sublist(4700 * 2, 4710 * 2));
    final dop = DopAudioSource(dsd);
    final wav = await _collect(dop.bytes(0, dop.length));
    expect(wav.length, dop.length);
    final o = DopAudioSource.headerSize;
    expect([wav[o + 2], wav[o + 1], wav[o]], [0x05, flat[0], flat[2]]);
    expect(wav[o + 6 + 2], 0xFA);
  });

  test('the reference decoder reads these images the same way', () async {
    final ref = _reference;
    if (ref == null) return markTestSkipped('set SACD_REFERENCE to the sacd binary to cross-check');
    final iso = stereoIso();
    final out = Directory('${dir.path}/ref')..createSync();
    final r = await Process.run(ref, ['-i', iso, '-o', out.path, '-s', '-r', '88200']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final wavs = out.listSync().whereType<File>().map((f) => f.path).toList()..sort();
    expect(wavs.map((p) => p.split('/').last), [
      '(2ch) 01. Singer A - First Song.wav',
      '(2ch) 02. Singer B - Second Song.wav',
    ]);
    final a = (await _decode(wavs[0]))!, b = (await _decode(wavs[1]))!;
    expect(a.length / 44100, closeTo(1, 0.05));
    expect(b.length / 44100, closeTo(0.6, 0.05));
    expect(_frequency(a.sublist(4410), 44100), closeTo(1000, 15));
    expect(_frequency(b.sublist(4410), 44100), closeTo(500, 10));
  });

  group('DST', () {
    // A real DST stream from FFmpeg's test suite: 10 frames.
    late List<Uint8List> dstFrames;
    late String original;
    setUpAll(() async {
      original = '${Directory.systemTemp.path}/openmusic-dst-64fs44-2ch.dff';
      if (!File(original).existsSync()) {
        final c = HttpClient();
        try {
          final req = await c.getUrl(Uri.parse('https://fate-suite.ffmpeg.org/dst/dst-64fs44-2ch.dff'));
          final res = await req.close();
          if (res.statusCode == 200) await res.pipe(File(original).openWrite());
        } catch (_) {
        } finally {
          c.close();
        }
      }
      dstFrames = [];
      if (!File(original).existsSync()) return;
      final b = File(original).readAsBytesSync();
      final v = ByteData.sublistView(b);
      for (var o = 0; o + 12 <= b.length;) {
        final id = String.fromCharCodes(b.sublist(o, o + 4));
        final size = v.getUint64(o + 4);
        if (id == 'FRM8') {
          o += 16;
          continue;
        }
        if (id == 'DST ') {
          o += 12;
          continue;
        }
        if (id == 'DSTF') dstFrames.add(b.sublist(o + 12, o + 12 + size));
        o += 12 + size + (size & 1);
      }
    });

    String dstIso() {
      final path = '${dir.path}/dst.iso';
      writeSacdIso(
        path,
        album: 'DST Album',
        artist: 'Someone',
        areas: [
          IsoArea(channels: 2, dst: true, tracks: [IsoTrack('Compressed', 'Someone', dstFrames)]),
        ],
      );
      return path;
    }

    test('live: DST songs decode exactly like the original DST file', () async {
      if (dstFrames.length != 10) return markTestSkipped('FATE sample not available');
      final disc = SacdDisc.read(dstIso())!;
      expect(disc.area.dst, isTrue);
      final track = disc.area.tracks.single;
      expect(track.frames, 10);
      expect(await SacdFrameReader(disc, track).frames(0, 10).toList(), dstFrames);
      final source = SacdAudioSource(disc, track);
      final dff = File('${dir.path}/virtual-dst.dff')..writeAsBytesSync(await _collect(source.bytes(0, source.length)));
      Future<List<int>?> pcm(String p) async {
        final r = await Process.run('ffmpeg', ['-v', 'error', '-i', p, '-f', 's32le', '-'], stdoutEncoding: null);
        return r.exitCode == 0 ? r.stdout as List<int> : null;
      }

      final want = await pcm(original);
      if (want == null) return markTestSkipped('ffmpeg without DST');
      final got = await pcm(dff.path);
      expect(got, isNotNull);
      expect(got!.length, want.length);
      expect(got, want, reason: 'bit-identical decode');

      final ref = _reference;
      if (ref == null) return;
      // Its DST decoder works one frame per CPU in parallel and drops the last
      // batch, so give it a longer song (DST frames decode independently).
      final long = '${dir.path}/dst-long.iso';
      writeSacdIso(
        long,
        album: 'DST Album',
        artist: 'Someone',
        areas: [
          IsoArea(
            channels: 2,
            dst: true,
            tracks: [
              IsoTrack('Compressed', 'Someone', [for (var i = 0; i < 30; i++) ...dstFrames]),
            ],
          ),
        ],
      );
      final out = Directory('${dir.path}/ref-dst')..createSync();
      final r = await Process.run(ref, ['-i', long, '-o', out.path, '-s', '-r', '88200']);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final decoded = (await _decode(out.listSync().whereType<File>().single.path))!;
      // 300 frames = 4 s, less what the decoder drops at the end.
      expect(decoded.length / 44100, greaterThan(3.5));
      final ours = SacdDisc.read(long)!;
      final ourSource = SacdAudioSource(ours, ours.area.tracks.single);
      final ourDff = File('${dir.path}/ours-long.dff')
        ..writeAsBytesSync(await _collect(ourSource.bytes(0, ourSource.length)));
      final mine = (await _decode(ourDff.path))!;
      // Same audio from both decoders (different filters): compare loudness.
      double rms(Int16List x) => math.sqrt(x.fold<double>(0, (s, v) => s + v * v) / x.length);
      expect(rms(mine.sublist(4410, 4410 * 8)), closeTo(rms(decoded.sublist(4410, 4410 * 8)), rms(mine) * 0.1));
    });
  });
}
