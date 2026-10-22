// The volume control through the real libmpv: what mpv renders is measured,
// so a lost level (e.g. a slider drag's commands racing the filter chain)
// shows up as the wrong gain. Then the controls: slider, wheel, Ctrl+↑/↓,
// mute, the level kept for the next launch, and the title bar's ⋯ menu.
//
// Opens the app's window; run it with a throwaway app-data directory (the
// YouTube Music session lives there):
//   flutter test integration_test/zz_volume_test.dart -d windows   (or -d linux)
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
      if (format == 0xFFFE) format = b.getUint16(at + 32, Endian.little); // extensible: the subformat GUID
    } else if (id == 'data') {
      final end = size == 0 || size == 0xFFFFFFFF ? b.lengthInBytes : math.min(at + 8 + size, b.lengthInBytes);
      final step = bits! ~/ 8;
      // The second half only: what was filtered before a change still sits in the output's
      // buffer (ao=pcm keeps 64 Ki frames, 1.4 s; a sound card's is about 0.2 s).
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
