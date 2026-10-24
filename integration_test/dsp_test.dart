// The sound-changing settings through this platform's own libmpv, measured:
// Mono audio, Virtual speakers, crossfeed and room correction. mpv renders
// into WAV files (ao=pcm), nothing is heard and nothing runs on a host, so the
// same test proves each platform's build (Linux, Windows, Android, macOS, iOS).
//
//   flutter test integration_test/dsp_test.dart -d <linux|windows|macos|emulator-5554|iPhone…>
//
// On a desktop, run it with a throwaway app-data directory and in a headless
// session (see AGENT.md).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:openmusic/services/audio_engine.dart';
import 'package:openmusic/services/player_controller.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A 16-bit stereo 48 kHz WAV of [frames] frames; [sample] gives (left, right) in −1..1.
File _wav(String path, int frames, (double, double) Function(int i) sample) {
  final data = ByteData(44 + frames * 4);
  void tag(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + frames * 4, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 2, Endian.little)
    ..setUint32(24, 48000, Endian.little)
    ..setUint32(28, 48000 * 4, Endian.little)
    ..setUint16(32, 4, Endian.little)
    ..setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  for (var i = 0; i < frames; i++) {
    final (l, r) = sample(i);
    data
      ..setInt16(44 + i * 4, (l * 32767).round(), Endian.little)
      ..setInt16(46 + i * 4, (r * 32767).round(), Endian.little);
  }
  return File(path)..writeAsBytesSync(data.buffer.asUint8List());
}

/// What mpv wrote: its rate, and each channel's RMS in dBFS over the second half
/// (what was filtered before a change may still sit in the output's buffer).
({int rate, List<double> db}) _measure(File wav) {
  final b = ByteData.sublistView(wav.readAsBytesSync());
  var at = 12;
  int? format, bits, channels, rate;
  while (at + 8 <= b.lengthInBytes) {
    final id = String.fromCharCodes(Uint8List.sublistView(b, at, at + 4));
    final size = b.getUint32(at + 4, Endian.little);
    if (id == 'fmt ') {
      format = b.getUint16(at + 8, Endian.little);
      channels = b.getUint16(at + 10, Endian.little);
      rate = b.getUint32(at + 12, Endian.little);
      bits = b.getUint16(at + 22, Endian.little);
      if (format == 0xFFFE) format = b.getUint16(at + 32, Endian.little); // extensible: the subformat GUID
    } else if (id == 'data') {
      final end = size == 0 || size == 0xFFFFFFFF ? b.lengthInBytes : math.min(at + 8 + size, b.lengthInBytes);
      final step = bits! ~/ 8, frame = step * channels!;
      final start = at + 8 + (end - at - 8) ~/ 2 ~/ frame * frame;
      final sums = List.filled(channels, 0.0);
      var n = 0;
      for (var i = start; i + frame <= end; i += frame, n++) {
        for (var c = 0; c < channels; c++) {
          final p = i + c * step;
          final v = switch ((format, bits)) {
            (3, 32) => b.getFloat32(p, Endian.little),
            (3, 64) => b.getFloat64(p, Endian.little),
            (1, 16) => b.getInt16(p, Endian.little) / 32768,
            (1, 32) => b.getInt32(p, Endian.little) / 2147483648,
            _ => throw StateError('unexpected WAV format $format/$bits'),
          };
          sums[c] += v * v;
        }
      }
      return (rate: rate!, db: [for (final s in sums) s == 0 ? -200.0 : 10 * math.log(s / n) / math.ln10]);
    }
    at += 8 + size + (size & 1);
  }
  throw StateError('no data in ${wav.path}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true, android: true, macOS: true, iOS: true);

  testWidgets('mono, virtual speakers, crossfeed and room correction change what mpv renders', (tester) async {
    // Discord off: the real one, if running, would show the test song on the user's profile.
    SharedPreferences.setMockInitialValues({'discord.enabled': false});
    // macOS outside the App Store sandbox: the caches folder isn't there until something makes it.
    final dir = ((await getTemporaryDirectory())..createSync(recursive: true)).createTempSync('om-dsp');
    addTearDown(() => dir.deleteSync(recursive: true));
    // 440 Hz on the left only, at −6 dBFS (−9 dBFS RMS).
    final song = _wav('${dir.path}/left.wav', 48000 * 4, (i) => (0.5 * math.sin(2 * math.pi * 440 * i / 48000), 0));
    // A unit impulse, in a folder whose name FFmpeg's graph syntax would take apart unescaped.
    final odd = Directory("${dir.path}/O'Brien [IR], a;b")..createSync();
    final dirac = _wav('${odd.path}/dirac.wav', 480, (i) => i == 0 ? (1, 1) : (0, 0));

    final c = PlayerController();
    await c.load();
    await c.setAutoplay(false);
    var out = '';
    final apply = JustAudioMediaKit.onPlayerCreated!;
    JustAudioMediaKit.onPlayerCreated = (p) {
      apply(p);
      // Into the file, never the device: the song waits for this before it opens the output.
      final mpv = p.platform as NativePlayer;
      final file = out;
      final silent = () async {
        await mpv.setProperty('ao', 'pcm');
        await mpv.setProperty('ao-pcm-file', file);
        await mpv.setProperty('ao-pcm-waveheader', 'yes');
      }();
      mpv.onLoadHooks.add(() => silent);
    };
    addTearDown(() => JustAudioMediaKit.onPlayerCreated = apply);

    var n = 0;
    final stages = <String, List<String>>{};

    /// Plays the song through mpv with [change] made first; what came out.
    Future<({int rate, List<double> db})> render(String name, Future<void> Function() change) async {
      out = '${dir.path}/out${n++}.wav';
      // Each step in real time: in the test's fake time, a player call that waits on a
      // timer inside just_audio or media_kit never returns (it hung about one run in seven).
      Future<T?> step<T>(String what, Future<T> Function() f) => tester.runAsync(
        () => f().timeout(const Duration(seconds: 30), onTimeout: () => throw StateError('$name: $what hung')),
      );
      await step('stop', c.player.stop); // a new mpv player, writing to [out]
      await step('the settings', change);
      await step('loading', () => c.player.setAudioSource(AudioSource.file(song.path)));
      await tester.pump(const Duration(milliseconds: 300));
      // Not awaited: just_audio's play() returns only when playback stops, and a stall must fail here.
      unawaited(c.player.play());
      final sw = Stopwatch()..start();
      while (c.player.processingState != ProcessingState.completed) {
        if (sw.elapsed > const Duration(seconds: 60)) {
          final mpv = JustAudioMediaKit.activePlayer!.platform as NativePlayer;
          final state = await tester.runAsync(() async {
            final values = <String>[];
            for (final k in ['current-ao', 'ao', 'pause', 'core-idle', 'eof-reached', 'time-pos', 'af']) {
              values.add('$k=${await mpv.getProperty(k)}');
            }
            return values.join(' ');
          });
          fail('$name never finished (${c.player.processingState} at ${c.player.position}; mpv: $state)');
        }
        if (!stages.containsKey(name)) {
          final path = await step('the signal path', c.audio.signalPath);
          if (path != null) stages[name] = path.filters;
        }
        await tester.pump(const Duration(milliseconds: 20));
      }
      await step('stop after', c.player.stop); // closes (and finishes) the WAV
      await tester.pump(const Duration(milliseconds: 300));
      final m = _measure(File(out));
      // ignore: avoid_print
      print('DSP $name: ${m.db.map((d) => d.toStringAsFixed(2)).join(' / ')} dB at ${m.rate} Hz, ${stages[name]}');
      return m;
    }

    final dry = await render('dry', () async {});
    expect(dry.db[0], closeTo(-9.03, 0.3));
    expect(dry.db[1], lessThan(-100));

    final both = await render('mono both ears', () => c.audio.setMono(MonoAudio.both));
    expect(both.db[0], closeTo(dry.db[0] - 6.02, 0.2), reason: 'each ear gets half of left plus right');
    expect(both.db[1], closeTo(both.db[0], 0.05));

    final left = await render('mono left', () => c.audio.setMono(MonoAudio.left));
    expect(left.db[0], closeTo(both.db[0], 0.05));
    expect(left.db[1], lessThan(-100), reason: 'nothing on the right');

    final right = await render('mono right', () => c.audio.setMono(MonoAudio.right));
    expect(right.db[1], closeTo(both.db[0], 0.05));
    expect(right.db[0], lessThan(-100), reason: 'nothing on the left');

    final speakers = await render('virtual speakers', () async {
      await c.audio.setMono(MonoAudio.off);
      await c.audio.setVirtualSpeakers(true);
    });
    expect(c.audio.hrirPath, isNotNull, reason: 'the HRIR asset became a file');
    expect(speakers.rate, 48000);
    expect(speakers.db[1], greaterThan(speakers.db[0] - 20), reason: 'the right ear hears the left speaker too');
    expect(speakers.db[1], lessThan(speakers.db[0]), reason: 'but quieter, from across the head');

    final crossfed = await render('crossfeed', () async {
      await c.audio.setVirtualSpeakers(false);
      await c.audio.setCrossfeed(0.5);
    });
    expect(crossfed.db[1], greaterThan(-60), reason: 'some of the left reaches the right');
    expect(crossfed.db[1], lessThan(crossfed.db[0]));

    final corrected = await render('room correction', () async {
      await c.audio.setCrossfeed(0);
      c.audio
        ..impulsePath = dirac.path
        ..impulseName = 'dirac';
      await c.audio.setConvolution(true);
    });
    expect(corrected.db[0], closeTo(dry.db[0], 0.5), reason: 'a unit impulse leaves the sound as it is');
    expect(stages['room correction'], contains('Room correction (dirac)'), reason: 'the graph opened the odd path');

    c.dispose();
  });
}
