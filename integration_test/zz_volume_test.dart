// The volume control through the real libmpv: what mpv renders is measured,
// so a lost level (e.g. a slider drag's commands racing the filter chain)
// shows up as the wrong gain. Then the controls: slider, wheel, Ctrl+↑/↓,
// mute, the level kept for the next launch, and the title bar's ⋯ menu.
// Also: a level set during a song still holds when the next one starts.
//
// Opens the app's window; run it with a throwaway app-data directory (the
// YouTube Music session lives there):
//   flutter test integration_test/zz_volume_test.dart -d windows   (or -d linux)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:openmusic/main.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/appearance.dart';
import 'package:openmusic/services/player_controller.dart';
import 'package:openmusic/ui/widgets/controls.dart';
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

/// RMS (dBFS) of a WAV mpv wrote: PCM 16/32-bit or float 32/64, any layout.
/// Measured [from] that fraction of the samples on.
double _rmsDb(File wav, {double from = 0.5}) {
  final b = ByteData.sublistView(wav.readAsBytesSync());
  var at = 12;
  int? format, bits;
  while (at + 8 <= b.lengthInBytes) {
    final id = String.fromCharCodes(Uint8List.sublistView(b, at, at + 4));
    final size = b.getUint32(at + 4, Endian.little);
    if (id == 'fmt ') {
      format = b.getUint16(at + 8, Endian.little);
      bits = b.getUint16(at + 22, Endian.little);
      if (format == 0xFFFE) format = b.getUint16(at + 32, Endian.little); // extensible: the subformat GUID
    } else if (id == 'data') {
      final end = size == 0 || size == 0xFFFFFFFF ? b.lengthInBytes : math.min(at + 8 + size, b.lengthInBytes);
      final step = bits! ~/ 8;
      // The second half by default: what was filtered before a change still sits in the
      // output's buffer (ao=pcm keeps 64 Ki frames, 1.4 s; a sound card's is about 0.2 s).
      final start = at + 8 + ((end - at - 8) * from).floor() ~/ step * step;
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);

  late Directory dir;
  setUp(() {
    // Discord off: the real one, if running, would show these test songs on the user's profile.
    SharedPreferences.setMockInitialValues({'discord.enabled': false});
    dir = Directory.systemTemp.createTempSync('om-volume');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('what mpv renders follows the volume, however fast it changes', (tester) async {
    final sine = _sine('${dir.path}/sine.wav');
    final c = PlayerController();
    await c.load();
    await c.setAutoplay(false);

    // Every new mpv player (after each stop) renders into the next file.
    var out = '';
    final apply = JustAudioMediaKit.onPlayerCreated!;
    JustAudioMediaKit.onPlayerCreated = (p) async {
      final mpv = p.platform as NativePlayer;
      await mpv.setProperty('ao', 'pcm');
      await mpv.setProperty('ao-pcm-file', out);
      await mpv.setProperty('ao-pcm-waveheader', 'yes');
      apply(p);
    };
    addTearDown(() => JustAudioMediaKit.onPlayerCreated = apply);

    var n = 0;

    /// Loads the sine paused, runs [change], then lets mpv render it all; the level in dBFS.
    Future<double> render(Future<void> Function() change) async {
      out = '${dir.path}/out${n++}.wav';
      await c.player.stop();
      await c.player.setAudioSource(AudioSource.file(sine.path));
      await tester.pump(const Duration(milliseconds: 300));
      await change();
      await tester.pump(const Duration(milliseconds: 300));
      await c.player.play();
      final sw = Stopwatch()..start();
      while (c.player.processingState != ProcessingState.completed) {
        if (sw.elapsed > const Duration(seconds: 30)) fail('render $n never finished');
        await tester.pump(const Duration(milliseconds: 20));
      }
      await c.player.stop(); // closes (and finishes) the WAV
      await tester.pump(const Duration(milliseconds: 300));
      final db = _rmsDb(File(out));
      debugPrint('VOLUME render $n: ${db.toStringAsFixed(2)} dBFS');
      return db;
    }

    final full = await render(() => c.setVolume(1));
    expect(full, closeTo(-9.03, 0.3), reason: 'a −6 dBFS sine has an RMS of −9 dBFS: 100% is untouched');

    // A slider drag: dozens of levels without waiting for each, ending at half way.
    final dragged = await render(() async {
      final calls = [for (var i = 0; i <= 40; i++) c.setVolume(1 - i / 80)];
      await Future.wait(calls);
    });
    expect(c.volume, closeTo(0.5, 1e-6));
    expect(dragged - full, closeTo(-18.06, 0.3), reason: 'half way on the slider is −18 dB, and the last level wins');

    // Down to nothing and back up: the filter leaves the chain and returns.
    final muted = await render(c.toggleMute);
    expect(muted, lessThan(-100), reason: 'muted is silent');
    final unmuted = await render(c.toggleMute);
    expect(c.volume, closeTo(0.5, 1e-6), reason: 'Unmute goes back to where it was, not to 100%');
    expect(unmuted - full, closeTo(-18.06, 0.3));

    // Back to 100% from a lower level: untouched again.
    final back = await render(() => c.setVolume(1));
    expect(back - full, closeTo(0, 0.05));

    // just_audio's own volume (its Android interruption handling doubles it once a
    // notification has ducked the music) changes neither what plays nor the slider.
    await c.setVolume(0.5);
    final ducked = await render(() => c.player.setVolume(1));
    expect(c.volume, 0.5);
    expect(ducked - full, closeTo(-18.06, 0.3), reason: 'still the slider\'s level');

    c.dispose();
  });

  testWidgets('the level kept from the last launch is what the first song plays at', (tester) async {
    SharedPreferences.setMockInitialValues({'discord.enabled': false, 'volume.v1': 0.5});
    final c = PlayerController();
    await c.load();
    await c.setAutoplay(false);
    expect(c.volume, 0.5, reason: 'the slider starts where it was left');
    expect(c.volumeLevel.value, 0.5);
    expect(c.audio.volume, closeTo(0.125, 1e-9), reason: 'the engine has its gain before any player exists');

    final sine = _sine('${dir.path}/sine.wav');
    final out = '${dir.path}/first.wav';
    final apply = JustAudioMediaKit.onPlayerCreated!;
    JustAudioMediaKit.onPlayerCreated = (p) async {
      final mpv = p.platform as NativePlayer;
      await mpv.setProperty('ao', 'pcm');
      await mpv.setProperty('ao-pcm-file', out);
      await mpv.setProperty('ao-pcm-waveheader', 'yes');
      apply(p);
    };
    addTearDown(() => JustAudioMediaKit.onPlayerCreated = apply);

    await c.player.setAudioSource(AudioSource.file(sine.path));
    unawaited(c.player.play());
    final sw = Stopwatch()..start();
    while (c.player.processingState != ProcessingState.completed) {
      if (sw.elapsed > const Duration(seconds: 30)) fail('the song never finished');
      await tester.pump(const Duration(milliseconds: 20));
    }
    await c.player.stop(); // closes (and finishes) the WAV
    await tester.pump(const Duration(milliseconds: 300));
    // From the start: the first song mustn't begin louder and settle later.
    final db = _rmsDb(File(out), from: 0.05);
    debugPrint('VOLUME first song after a launch: ${db.toStringAsFixed(2)} dBFS');
    expect(db, closeTo(-9.03 - 18.06, 0.3), reason: 'half way on the slider is −18 dB');
    c.dispose();
  });

  /// A playlist of [songs] (each a −6 dBFS sine of that many seconds) on [c]'s player.
  Future<void> playlist(PlayerController c, List<int> songs) async {
    await c.player.setAudioSources([
      for (final (i, seconds) in songs.indexed)
        if (_sine('${dir.path}/song$i.wav', seconds: seconds) case final f)
          AudioSource.file(f.path, tag: Track.fromUri(Uri.file(f.path))),
    ]);
  }

  /// Waits until mpv's audio flows (not loading, paused or between songs).
  Future<void> flowing(WidgetTester tester, NativePlayer mpv) async {
    final sw = Stopwatch()..start();
    while (await mpv.getProperty('core-idle') != 'no') {
      if (sw.elapsed > const Duration(seconds: 10)) fail('the song never played');
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  /// A slider drag from 100% down to [level] (gain [level]³): a level every 10 ms, as a
  /// pointer moves, none waiting for the one before.
  Future<void> drag(WidgetTester tester, PlayerController c, double level) async {
    final steps = <Future<void>>[];
    for (var i = 0; i <= 40; i++) {
      steps.add(c.setVolume(1 - (1 - level) * i / 40));
      await tester.pump(const Duration(milliseconds: 10));
    }
    await Future.wait(steps);
  }

  testWidgets('through the system mixer, a level set during a song is mpv\'s own and holds for the next one', (
    tester,
  ) async {
    final c = PlayerController();
    await c.load();
    await c.setAutoplay(false);
    final out = '${dir.path}/next.wav';
    final apply = JustAudioMediaKit.onPlayerCreated!;
    JustAudioMediaKit.onPlayerCreated = (p) async {
      final mpv = p.platform as NativePlayer;
      await mpv.setProperty('ao', 'pcm');
      await mpv.setProperty('ao-pcm-file', out);
      await mpv.setProperty('ao-pcm-waveheader', 'yes');
      apply(p);
    };
    addTearDown(() => JustAudioMediaKit.onPlayerCreated = apply);

    await c.setVolume(1);
    await c.player.stop();
    // mpv renders ao=pcm faster than real time: song one is long so the level surely changes in it.
    await playlist(c, [60, 10]);
    await tester.pump(const Duration(milliseconds: 300));
    unawaited(c.player.play());
    final mpv = JustAudioMediaKit.activePlayer!.platform as NativePlayer;
    await flowing(tester, mpv);
    // In one burst: song one renders in a fraction of a second (mpv's own volume has no chain to go stale).
    await Future.wait([for (var i = 0; i <= 40; i++) c.setVolume(1 - i / 80)]);
    expect(await mpv.getProperty('playlist-pos'), '0', reason: 'the level changed during song one');
    expect(await mpv.getProperty('af'), isNot(contains('@volume')), reason: 'no filter: mpv applies it');
    expect(double.parse(await mpv.getProperty('volume')), closeTo(50, 1e-3), reason: 'mpv\'s gain is (volume / 100)³');
    // mpv's own end of song two (just_audio may miss "completed" at this speed).
    final sw = Stopwatch()..start();
    while (await mpv.getProperty('playlist-pos') != '1' || await mpv.getProperty('eof-reached') != 'yes') {
      if (sw.elapsed > const Duration(seconds: 60)) fail('the songs never finished');
      await tester.pump(const Duration(milliseconds: 20));
    }
    await c.player.stop(); // closes (and finishes) the WAV
    await tester.pump(const Duration(milliseconds: 300));

    // The last 9 s are song two, a −6 dBFS sine (RMS −9 dBFS), at half way: −18 dB.
    final db = _rmsDb(File(out), from: 1 - 9 / 70);
    debugPrint('VOLUME next song through the mixer: ${db.toStringAsFixed(2)} dBFS');
    expect(db, closeTo(-9.03 - 18.06, 0.3), reason: 'song two plays at the level set during song one');
    c.dispose();
  });

  testWidgets('the 64-bit filter\'s level holds for the next song and when filters are rebuilt', (tester) async {
    // Bit-perfect mode keeps the filter. (A missing card, so it doesn't take the real one from the desktop.)
    SharedPreferences.setMockInitialValues({
      'discord.enabled': false,
      'audio.v1': jsonEncode({'bitPerfect': true, 'device': 'alsa/no-such-card'}),
    });
    final c = PlayerController();
    await c.load();
    await c.setAutoplay(false);
    // mpv's null output plays in real time, so the level changes while a song plays: the
    // running filter gets it, and mpv's `af` (each song's filters are built from it) doesn't.
    final apply = JustAudioMediaKit.onPlayerCreated!;
    JustAudioMediaKit.onPlayerCreated = (p) async {
      await (p.platform as NativePlayer).setProperty('ao', 'null');
      apply(p);
    };
    addTearDown(() => JustAudioMediaKit.onPlayerCreated = apply);

    await c.setVolume(1);
    await c.player.stop();
    await playlist(c, [20, 20]);
    unawaited(c.player.play());
    final mpv = JustAudioMediaKit.activePlayer!.platform as NativePlayer;
    await flowing(tester, mpv);
    await tester.pump(const Duration(milliseconds: 300));

    await drag(tester, c, 0.5);
    expect(await mpv.getProperty('af'), contains('@volume'), reason: 'the filter applies it');
    expect(double.parse(await mpv.getProperty('volume')), 100, reason: 'mpv must not scale the samples too');
    // Straight on to song two, before the drag counts as settled.
    final skipped = Stopwatch()..start();
    await c.player.seekToNext();
    while (await mpv.getProperty('playlist-pos') != '1') {
      await tester.pump(const Duration(milliseconds: 5));
    }
    await flowing(tester, mpv);
    final af = await mpv.getProperty('af');
    debugPrint('VOLUME song two\'s filters, ${skipped.elapsedMilliseconds} ms after the drag: $af');
    expect(skipped.elapsed, lessThan(const Duration(milliseconds: 450)), reason: 'before the settled-drag update');
    expect(af, contains('volume=0.125000'), reason: 'song two\'s filters are built at the level set during song one');

    // A drag during song two: once it settles, `af` has the level too, so filters mpv rebuilds
    // by itself mid-song (its output reopening) don't go back to the old one.
    await drag(tester, c, 0.25);
    expect(await mpv.getProperty('af'), isNot(contains('volume=0.015625')), reason: 'the running filter has it');
    await tester.pump(const Duration(milliseconds: 900));
    expect(await mpv.getProperty('af'), contains('volume=0.015625'));
    await c.player.stop();
    c.dispose();
  });

  testWidgets('volume controls, the level kept for next time, and the ⋯ menu', (tester) async {
    final c = PlayerController();
    await c.load();
    await tester.pumpWidget(OpenMusicApp(controller: c));
    await tester.pump(const Duration(seconds: 2));

    final slider = find.descendant(of: find.byType(VolumeSlider), matching: find.byType(Slider));
    expect(slider, findsOneWidget, reason: 'the volume slider is in the player bar');
    double sliderValue() => tester.widget<Slider>(slider).value;
    expect(sliderValue(), 1);

    // The mouse wheel over it.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(slider)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.volume, closeTo(0.95, 1e-6));
    expect(sliderValue(), closeTo(0.95, 1e-6));

    // Dragging the slider all the way left.
    await tester.drag(slider, const Offset(-300, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.volume, 0);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);

    // Unmute after dragging to 0: back to where the drag started.
    await tester.tap(find.byTooltip('Unmute'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.volume, closeTo(0.95, 1e-6));

    // Ctrl+↓ twice, Ctrl+↑ once.
    for (final key in [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowUp]) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(c.volume, closeTo(0.9, 1e-6));

    // Kept for the next launch.
    await tester.pump(const Duration(milliseconds: 800));
    expect((await SharedPreferences.getInstance()).getDouble('volume.v1'), closeTo(0.9, 1e-6));
    final next = PlayerController();
    await next.load();
    expect(next.volume, closeTo(0.9, 1e-6));
    addTearDown(next.dispose);

    // The ⋯ menu: Downloads and Settings, and Settings' own pages.
    expect(find.text('Settings'), findsNothing, reason: 'Settings left the sidebar');
    await tester.tap(find.byTooltip('More'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Downloads'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 800));
    for (final topic in ['Account', 'Appearance', 'Playback', 'Hi-fi audio', 'Downloads', 'Integrations']) {
      expect(find.text(topic), findsOneWidget, reason: '$topic is listed');
    }
    await tester.tap(find.text('Playback'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Equalizer'), findsOneWidget, reason: 'Playback has its own page');
    await tester.tap(find.byTooltip('Back'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Hi-fi audio'), findsOneWidget, reason: 'Back returns to the list');

    // The breadcrumb's "Settings" also returns to the list.
    await tester.tap(find.text('Appearance'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Theme'), findsOneWidget, reason: 'Appearance has its own page');

    // Text size: − and + step one pixel.
    await tester.ensureVisible(find.byTooltip('Larger'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('14 px'), findsOneWidget);
    await tester.tap(find.byTooltip('Larger'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(Appearance.instance.textSize, 15);
    expect(find.text('15 px'), findsOneWidget);
    await tester.tap(find.byTooltip('Smaller'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(Appearance.instance.textSize, 14);
    await tester.ensureVisible(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Hi-fi audio'), findsOneWidget, reason: 'the breadcrumb opens the list');

    await tester.tap(find.byTooltip('More'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Downloads').last); // the menu's, over the Settings list
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Hi-fi audio'), findsNothing, reason: 'Downloads replaced the Settings list');

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
