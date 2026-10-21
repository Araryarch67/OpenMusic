// StreamAudioSource is just_audio's documented byte-stream API.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:openmusic/services/cast.dart';
import 'package:openmusic/services/dlna.dart';
import 'package:openmusic/services/youtube_stream.dart';
import 'package:xml/xml.dart';

import 'support/fake_renderer.dart';

/// Serves fixed bytes the way YoutubeAudioSource serves a stream.
class _BytesSource extends StreamAudioSource {
  _BytesSource(this.bytes);
  final Uint8List bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = end ?? bytes.length;
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: to - from,
      offset: from,
      contentType: 'audio/mp4',
      stream: Stream.value(bytes.sublist(from, to)),
    );
  }
}

Future<void> _until(bool Function() done, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('protocol', () {
    test('search replies: renderers only, with an http LOCATION', () {
      const reply =
          'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\n'
          'LOCATION: http://192.168.1.20:49152/description.xml\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:tv::urn:...\r\n\r\n';
      expect(Dlna.parseSearchReply(reply), Uri.parse('http://192.168.1.20:49152/description.xml'));
      expect(Dlna.parseSearchReply(reply.replaceFirst('MediaRenderer', 'MediaServer')), isNull);
      expect(
        Dlna.parseSearchReply('M-SEARCH * HTTP/1.1\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'),
        isNull,
      );
    });

    test('description: the embedded renderer, its services and relative control URLs', () {
      final r = Dlna.parseDescription(Uri.parse('http://10.0.0.5:8080/dev/desc.xml'), fakeDescription)!;
      expect(r.name, 'Living Room TV');
      expect(r.id, 'uuid:tv-1');
      expect(r.avTransport, Uri.parse('http://10.0.0.5:8080/dev/av/control'));
      expect(r.avTransportType, 'urn:schemas-upnp-org:service:AVTransport:1');
      expect(r.renderingControl, Uri.parse('http://10.0.0.5:8080/rc'));
      expect(Dlna.parseDescription(Uri.parse('http://x/'), fakeDescription.replaceAll('AVTransport', 'Nope')), isNull);
    });

    test('times', () {
      expect(Dlna.formatTime(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
      expect(Dlna.formatTime(const Duration(seconds: 61, milliseconds: 50), millis: true), '0:01:01.050');
      expect(Dlna.parseTime('0:03:25'), const Duration(minutes: 3, seconds: 25));
      expect(Dlna.parseTime('00:00:01.500'), const Duration(seconds: 1, milliseconds: 500));
      expect(Dlna.parseTime('NOT_IMPLEMENTED'), isNull);
    });

    test('byte ranges', () {
      expect(CastServer.parseRange('bytes=0-', 100), (start: 0, end: 99));
      expect(CastServer.parseRange('bytes=10-19', 100), (start: 10, end: 19));
      expect(CastServer.parseRange('bytes=90-500', 100), (start: 90, end: 99));
      expect(CastServer.parseRange('bytes=-10', 100), (start: 90, end: 99));
      expect(CastServer.parseRange('bytes=100-', 100), isNull);
      expect(CastServer.parseRange(null, 100), isNull);
    });

    test('metadata is escaped and names the format', () {
      final didl = DlnaControl.didl(
        url: Uri.parse('http://h/m/a.flac'),
        mime: 'audio/flac',
        title: 'Rock & <Roll>',
        artist: 'A "B"',
        duration: const Duration(minutes: 3),
      );
      final doc = XmlDocument.parse(didl);
      expect(doc.findAllElements('dc:title').single.innerText, 'Rock & <Roll>');
      final res = doc.findAllElements('res').single;
      expect(res.getAttribute('protocolInfo'), startsWith('http-get:*:audio/flac:DLNA.ORG_OP=01'));
      expect(res.getAttribute('duration'), '0:03:00.000');
    });
  });

  group('casting to a renderer', () {
    late FakeRenderer tv;
    late DlnaRenderer renderer;
    late Directory dir;
    late Cast cast;
    var ended = 0;
    final errors = <String>[];

    setUp(() async {
      tv = FakeRenderer();
      await tv.start();
      renderer = (await Dlna.describe(tv.location))!;
      dir = Directory.systemTemp.createTempSync('cast');
      ended = 0;
      errors.clear();
      cast = Cast(onEnded: () => ended++, onError: errors.add, pollEvery: const Duration(milliseconds: 50));
      await cast.connect(renderer);
    });

    tearDown(() async {
      cast.dispose();
      await tv.close();
      dir.deleteSync(recursive: true);
    });

    test('a file goes over byte for byte, with title, cover and controls', () async {
      final file = File('${dir.path}/song.flac')..writeAsBytesSync(List.generate(200000, (i) => i * 7 % 256));
      await _until(() => cast.volume == 30);
      await cast.load(
        CastItem(
          key: 'song',
          media: (_) => CastFile(file.path, 'audio/flac'),
          title: 'Song',
          artist: 'Band',
          duration: const Duration(minutes: 4),
          art: () async => Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]),
        ),
        from: const Duration(seconds: 30),
      );
      expect(tv.fetched, file.readAsBytesSync());
      expect(tv.fetchedType, 'audio/flac');
      expect(tv.ranges.length, greaterThan(1), reason: 'served in ranges');
      expect(tv.problems, isEmpty);
      final didl = XmlDocument.parse(tv.args['SetAVTransportURI']!['CurrentURIMetaData']!);
      expect(didl.findAllElements('dc:title').single.innerText, 'Song');
      final art = await http.get(Uri.parse(didl.findAllElements('upnp:albumArtURI').single.innerText));
      expect(art.headers['content-type'], 'image/png');
      expect(tv.actions, containsAllInOrder(['SetAVTransportURI', 'Play', 'Seek']));
      expect(tv.args['Seek']!['Target'], '0:00:30');

      await _until(() => cast.playing && !cast.loading);
      tv.position = const Duration(seconds: 42);
      await _until(() => cast.position >= const Duration(seconds: 42));

      await cast.pause();
      expect(tv.state, 'PAUSED_PLAYBACK');
      expect(cast.playing, isFalse);
      await cast.seek(const Duration(minutes: 1));
      expect(tv.args['Seek']!['Target'], '0:01:00');
      await cast.setVolume(55);
      expect(tv.volume, 55);
      expect(errors, isEmpty);

      // Only a stop near the end counts as the song ending.
      await cast.play();
      tv.state = 'STOPPED';
      await _until(() => !cast.playing);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(ended, 0, reason: 'stopped at 1:00 of 4:00 is the remote\'s Stop button');
      await cast.play();
      tv.position = const Duration(minutes: 3, seconds: 58);
      await _until(() => cast.position >= const Duration(minutes: 3, seconds: 58));
      tv.state = 'STOPPED';
      tv.position = Duration.zero;
      await _until(() => ended == 1);
    });

    test('a stream (YouTube) is proxied with ranges', () async {
      final bytes = Uint8List.fromList(List.generate(150000, (i) => i % 251));
      await cast.load(CastItem(key: 'yt', media: (_) => CastStream(_BytesSource(bytes), 'audio/mp4'), title: 'Song'));
      expect(tv.fetched, bytes);
      expect(tv.fetchedType, 'audio/mp4');
    });

    test('formats renderers rarely play are converted to FLAC; seeking restarts the conversion', () async {
      final src = '${dir.path}/song.wv';
      final made = await Process.run('ffmpeg', ['-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=d=6', src]);
      if (made.exitCode != 0) return markTestSkipped('ffmpeg not available');
      final starts = <Duration>[];
      final item = CastItem(
        key: 'wv',
        media: (from) {
          starts.add(from);
          return CastTranscode(src, start: const Duration(seconds: 1) + from, end: const Duration(seconds: 5));
        },
        title: 'Cue slice',
        duration: const Duration(seconds: 4),
      );
      await cast.load(item);
      expect(tv.ranges, [null], reason: 'not byte-seekable');
      Future<Duration> length() async {
        final f = File('${dir.path}/got.flac')..writeAsBytesSync(tv.fetched!);
        final probe = await Process.run('ffprobe', [
          '-v', 'error', '-show_entries', 'stream=codec_name', '-of', 'csv=p=0', f.path, //
        ]);
        expect((probe.stdout as String).trim(), 'flac');
        // A FLAC written to a pipe has no length in its header: decode it (1 kHz mono s16 = 2 bytes / ms).
        final pcm = await Process.run('ffmpeg', [
          '-v', 'error', '-i', f.path, '-f', 's16le', '-ac', '1', '-ar', '1000', '-', //
        ], stdoutEncoding: null);
        return Duration(milliseconds: (pcm.stdout as List<int>).length ~/ 2);
      }

      expect((await length()).inMilliseconds, closeTo(4000, 100), reason: 'only the slice');
      await _until(() => cast.playing && !cast.loading);
      await cast.seek(const Duration(seconds: 3));
      expect(starts.last, const Duration(seconds: 3));
      expect((await length()).inMilliseconds, closeTo(1000, 100));
      // The renderer counts from the new start: 0:00:01 there is 0:00:04 in the song.
      tv.position = const Duration(seconds: 1);
      await _until(() => cast.position >= const Duration(seconds: 4));
    });

    test('a renderer that stops answering ends the session', () async {
      tv.down = true;
      await _until(() => !cast.active);
      expect(errors.single, 'Lost connection to Living Room TV');
    });
  });

  test('live: YouTube songs are cast as AAC (TVs rarely decode Opus)', () async {
    final r = await YoutubeStream.best('dQw4w9WgXcQ', aac: true);
    expect(r.mimeType, 'audio/mp4');
    expect(r.codec, startsWith('mp4a'));
    expect(r.size, greaterThan(0));
  });

  test('finds a renderer with an SSDP search', () async {
    final tv = FakeRenderer();
    await tv.start();
    if (!await tv.answerSearches()) {
      await tv.close();
      return markTestSkipped('can\'t listen for SSDP here');
    }
    try {
      final found = await Dlna.discover(timeout: const Duration(seconds: 2)).toList();
      if (found.isEmpty) return markTestSkipped('no multicast on this machine\'s networks');
      expect(found.single.name, 'Living Room TV');
    } finally {
      await tv.close();
    }
  });
}
