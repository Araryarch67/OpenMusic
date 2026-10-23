// How much of the machine the app takes while a song plays and nothing else
// happens: CPU time (all threads: UI, raster, mpv) and frames drawn, over a
// few seconds of real time on Home, on a long song list and paused.
//
// A music player sits there playing for hours, so this is battery and fan
// noise. Profile mode, headless Weston, frames scheduled as in the real app:
//   tool/perf.sh --target=integration_test/cpu_test.dart
// Prints "CPU ..." lines.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:openmusic/main.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/player_controller.dart';
import 'package:openmusic/ui/shell_scope.dart';
import 'package:openmusic/ui/widgets/page_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User + system CPU time of this process so far (all threads), from /proc.
Duration _cpuTime() {
  final fields = File('/proc/self/stat').readAsStringSync().split(') ').last.split(' ');
  // utime and stime are fields 14 and 15 of the whole line; 12 and 13 after "pid (comm) ".
  final ticks = int.parse(fields[11]) + int.parse(fields[12]);
  return Duration(microseconds: ticks * 1000000 ~/ 100); // USER_HZ is 100 on Linux
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a playing song costs little', (tester) async {
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
    final dir = Directory.systemTemp.createTempSync('om-cpu');
    addTearDown(() => dir.deleteSync(recursive: true));
    final songs = <String>[];
    for (var i = 1; i <= 3; i++) {
      final f = '${dir.path}/song$i.flac';
      final r = await Process.run('ffmpeg', [
        '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'sine=f=${300 + i * 100}:d=240', //
        '-metadata', 'title=Song $i', '-metadata', 'artist=Artist', '-metadata', 'album=Album', f,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      songs.add(f);
    }
    final library = [
      for (final f in songs) Track.fromUri(Uri.file(f)),
      for (var i = 0; i < 2000; i++)
        Track(
          id: 'file:///nonexistent/$i.flac',
          uri: Uri.file('/nonexistent/$i.flac'),
          title: 'Song $i',
          artist: 'Artist ${i % 100}',
          album: 'Album ${i ~/ 10}',
          duration: const Duration(minutes: 3),
          tagged: true,
        ),
    ];
    SharedPreferences.setMockInitialValues({
      'library.v1': jsonEncode([for (final t in library) t.toJson()]),
    });

    final c = PlayerController();
    final apply = JustAudioMediaKit.onPlayerCreated!;
    JustAudioMediaKit.onPlayerCreated = (p) async {
      await (p.platform as NativePlayer).setProperty('ao', 'null');
      apply(p);
    };
    await c.load();
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 1.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(OpenMusicApp(controller: c));
    while (c.scanning) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // From here frames come when the app asks for them, as on a desktop.
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    var frames = 0;
    SchedulerBinding.instance.addTimingsCallback((t) => frames += t.length);

    Future<void> measure(String label) async {
      await Future<void>.delayed(const Duration(seconds: 2)); // settle
      frames = 0;
      final cpu = _cpuTime();
      final clock = Stopwatch()..start();
      await Future<void>.delayed(const Duration(seconds: 8));
      final used = _cpuTime() - cpu;
      final pct = used.inMicroseconds / clock.elapsedMicroseconds * 100;
      final fps = frames / (clock.elapsedMilliseconds / 1000);
      // ignore: avoid_print
      print('CPU $label: ${pct.toStringAsFixed(1)}% of one core, ${fps.toStringAsFixed(1)} frames/s');
    }

    await c.playList([
      for (final t in c.library)
        if (t.path?.startsWith(dir.path) ?? false) t,
    ], 0);
    await measure('playing, Home');
    ShellScope.of(tester.element(find.byType(PageScaffold).first)).openCollection(c.allSongs);
    await measure('playing, All Songs');
    await c.pause();
    await measure('paused, All Songs');
    await c.player.stop();
  });
}
