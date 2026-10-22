// Desktop features through the real libmpv and the network: the equalizer's
// effect measured in what mpv renders, crossfeed and the signal path, the
// output device list, a YouTube song streaming, and yt-dlp resolving one.
// Nothing is heard: output goes to mpv's pcm or null driver.
//
// Run it with a throwaway app-data directory (the YouTube Music session lives there):
//   flutter test integration_test/zz_desktop_features_test.dart -d windows   (or -d linux)
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer, Player;
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/appearance.dart';
import 'package:openmusic/services/audio_engine.dart';
import 'package:openmusic/services/player_controller.dart';
import 'package:openmusic/services/system_fonts.dart';
import 'package:openmusic/ui/theme.dart';
import 'package:openmusic/services/ytdlp.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [seconds] of a 1 kHz sine at −6 dBFS, 16-bit stereo 48 kHz.
File _sine(String path, {int seconds = 6}) {
  const rate = 48000;
  final frames = rate * seconds;
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
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 4, Endian.little)
    ..setUint16(32, 4, Endian.little)
    ..setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  for (var i = 0; i < frames; i++) {
    final s = (math.sin(2 * math.pi * 1000 * i / rate) * 16384).round();
    data
      ..setInt16(44 + i * 4, s, Endian.little)
      ..setInt16(46 + i * 4, s, Endian.little);
  }
  return File(path)..writeAsBytesSync(data.buffer.asUint8List());
}

/// RMS (dBFS) of the second half of a WAV mpv wrote (the first holds what the output had buffered).
double _rmsDb(File wav) {
  final b = ByteData.sublistView(wav.readAsBytesSync());
  var at = 12;
  int? format, bits;
  while (at + 8 <= b.lengthInBytes) {
    final id = String.fromCharCodes(Uint8List.sublistView(b, at, at + 4));
    final size = b.getUint32(at + 4, Endian.little);
    if (id == 'fmt ') {
      format = b.getUint16(at + 8, Endian.little);
      bits = b.getUint16(at + 22, Endian.little);
      if (format == 0xFFFE) format = b.getUint16(at + 32, Endian.little);
    } else if (id == 'data') {
      final end = size == 0 || size == 0xFFFFFFFF ? b.lengthInBytes : math.min(at + 8 + size, b.lengthInBytes);
      final step = bits! ~/ 8;
      final start = at + 8 + (end - at - 8) ~/ 2 ~/ step * step;
      var sum = 0.0;
      var n = 0;
      for (var i = start; i + step <= end; i += step) {
        final v = switch ((format, bits)) {
          (3, 32) => b.getFloat32(i, Endian.little),
          (3, 64) => b.getFloat64(i, Endian.little),
          (1, 16) => b.getInt16(i, Endian.little) / 32768,
          (1, 32) => b.getInt32(i, Endian.little) / 2147483648,
          _ => throw StateError('unexpected WAV format $format/$bits'),
        };
        sum += v * v;
        n++;
      }
      return n == 0 || sum == 0 ? double.negativeInfinity : 10 * math.log(sum / n) / math.ln10;
    }
    at += 8 + size + (size & 1);
  }
  throw StateError('no data in ${wav.path}');
}

Future<void> _until(WidgetTester tester, bool Function() done, String what, {int seconds = 30}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > Duration(seconds: seconds)) fail('$what: not after $seconds s');
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);

  late Directory dir;
  late PlayerController c;
  late void Function(Player) apply;
  setUp(() async {
    // Discord off: the real one, if running, would show these test songs on the user's profile.
    SharedPreferences.setMockInitialValues({'discord.enabled': false});
    dir = Directory.systemTemp.createTempSync('om-features');
    c = PlayerController();
    await c.load();
    await c.setAutoplay(false);
    apply = JustAudioMediaKit.onPlayerCreated!;
  });
  tearDown(() {
    JustAudioMediaKit.onPlayerCreated = apply;
    c.dispose();
    dir.deleteSync(recursive: true);
  });

  /// Every new mpv player (after each stop) uses these output properties.
  void outputTo(Map<String, String> props) {
    JustAudioMediaKit.onPlayerCreated = (p) async {
      final mpv = p.platform as NativePlayer;
      for (final e in props.entries) {
        await mpv.setProperty(e.key, e.value);
      }
      apply(p);
    };
  }

  testWidgets('the equalizer and crossfeed change what mpv renders', (tester) async {
    final sine = _sine('${dir.path}/sine.wav');
    var n = 0;
    Future<double> render() async {
      final out = '${dir.path}/out${n++}.wav';
      outputTo({'ao': 'pcm', 'ao-pcm-file': out, 'ao-pcm-waveheader': 'yes'});
      await c.player.stop();
      await c.player.setAudioSource(AudioSource.file(sine.path));
      await tester.pump(const Duration(milliseconds: 400));
      await c.player.play();
      await _until(tester, () => c.player.processingState == ProcessingState.completed, 'render $n');
      await c.player.stop();
      await tester.pump(const Duration(milliseconds: 300));
      final db = _rmsDb(File(out));
      debugPrint('FEATURES render $n: ${db.toStringAsFixed(2)} dBFS');
      return db;
    }

    final dry = await render();
    expect(dry, closeTo(-9.03, 0.3));

    // A −12 dB cut at 1 kHz: the sine drops by 12 dB (no headroom needed for a cut).
    final at1k = defaultEqFrequencies.indexOf(1000);
    await c.audio.setEqEnabled(true);
    await c.audio.setBand(at1k, const EqBand(1000, -12));
    expect(c.audio.filterChain, contains('@eq:'));
    final cut = await render();
    expect(cut - dry, closeTo(-12, 0.3), reason: 'the 1 kHz band at −12 dB');

    // A +6 dB boost: the preamp takes 6 dB first, so the boosted sine ends where it began.
    await c.audio.setBand(at1k, const EqBand(1000, 6));
    final boosted = await render();
    expect(boosted - dry, closeTo(0, 0.3), reason: 'boost minus the automatic headroom');
    await c.audio.setEqEnabled(false);

    // Crossfeed mixes each side into the other: identical channels come out a little louder, not silent.
    await c.audio.setCrossfeed(1);
    expect(c.audio.filterChain, contains('@crossfeed:'));
    final crossfed = await render();
    expect(crossfed, greaterThan(dry - 6));
    expect((crossfed - dry).abs(), greaterThan(0.05), reason: 'crossfeed changes the samples');
    await c.audio.setCrossfeed(0);
  });

  testWidgets('output devices, a YouTube song streaming, and its signal path', (tester) async {
    // The real outputs, listed (nothing is opened on them).
    outputTo({'ao': 'null'});
    await c.player.setAudioSource(AudioSource.file(_sine('${dir.path}/sine.wav').path));
    await tester.pump(const Duration(seconds: 1));
    await c.audio.refreshDevices();
    debugPrint('FEATURES devices: ${c.audio.devices.map((d) => '${d.name} (${d.description})').join(', ')}');
    expect(c.audio.devices.first.name, 'auto');
    if (Platform.isWindows) {
      expect(c.audio.devices.where((d) => d.name.startsWith('wasapi/')), isNotEmpty, reason: 'WASAPI outputs listed');
    }
    await c.player.stop();

    // A YouTube song plays (ao=null keeps real time, silently).
    await c.audio.setEqEnabled(true);
    await c.audio.setBand(defaultEqFrequencies.indexOf(1000), const EqBand(1000, -3));
    final song = Track.youtube(videoId: 'dQw4w9WgXcQ', title: 'Never Gonna Give You Up', artist: 'Rick Astley');
    await c.playList([song], 0, from: 'test');
    await _until(
      tester,
      () => c.player.playing && c.player.position > const Duration(seconds: 2),
      'YouTube song playing',
      seconds: 45,
    );

    final path = await c.audio.signalPath();
    expect(path, isNotNull);
    debugPrint(
      'FEATURES signal path: ${path!.codec} ${path.inFormat}/${path.inRate} → ${path.filters} → '
      '${path.output} ${path.outFormat}/${path.outRate}',
    );
    expect(path.codec.toLowerCase(), anyOf(contains('opus'), contains('aac')));
    expect(path.filters.join(' '), contains('Equalizer'), reason: 'the EQ is named in the signal path');
    await c.player.stop();
    await c.audio.setEqEnabled(false);
  });

  testWidgets('Windows\' volume mixer names the app OpenMusic, not mpv', (tester) async {
    if (!Platform.isWindows) return;
    // The real output (WASAPI), muted: the volume filter at 0 sends silence.
    await c.setVolume(0);
    await c.player.setAudioSource(AudioSource.file(_sine('${dir.path}/sine.wav', seconds: 20).path));
    unawaited(c.player.play());
    await _until(tester, () => c.player.position > const Duration(seconds: 1), 'playing');
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      'integration_test/windows_audio_sessions.ps1',
    ]);
    await c.player.stop();
    final ours = [
      for (final line in (r.stdout as String).split(RegExp(r'\r?\n')))
        if (line.startsWith('$pid\t')) line.substring('$pid\t'.length),
    ];
    debugPrint('FEATURES mixer: $ours (pid $pid) ${r.stderr}');
    expect(ours, isNotEmpty, reason: 'this app has an audio session');
    expect(ours, everyElement('OpenMusic'));
  });

  testWidgets('fonts from the font folders: found, and the app draws with the one picked', (tester) async {
    final fonts = await SystemFonts.scan();
    debugPrint('FEATURES fonts: ${fonts.length} families, e.g. ${fonts.take(5).map((f) => f.family).join(', ')}');
    expect(fonts, isNotEmpty);
    final pick = fonts.firstWhere((f) => f.family == 'Arial', orElse: () => fonts.first);
    expect(await Appearance.instance.setFont(pick), isTrue);
    expect(buildAppTheme(fontFamily: Appearance.instance.fontFamily).textTheme.bodyMedium?.fontFamily, pick.family);
    await Appearance.instance.setFont(null);
    expect(Appearance.instance.fontFamily, isNull, reason: 'back to OpenMusic\'s own');
  });

  testWidgets('yt-dlp resolves a song on this OS', (tester) async {
    if (!YtDlp.supported) return;
    final r = await YtDlp.resolve('dQw4w9WgXcQ');
    debugPrint('FEATURES yt-dlp: ${r.formatId} ${r.ext} ${r.codec} ${r.kbps} kbps, ${r.size} bytes');
    for (final field in [r.formatId, r.ext, r.codec]) {
      expect(field, isNot(contains('\r')), reason: 'Windows line ends are stripped');
    }
    expect(r.url.scheme, 'https');
    expect(r.size, isNotNull, reason: 'the stream\'s size is known');
    expect(r.kbps, isNotNull);
  });
}
