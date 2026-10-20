// How long the user waits: from pressing play (or next, or a seek) until the
// song is actually playing. YouTube songs need the network; output goes to
// mpv's null driver, so nothing is heard.
//
// Run it in profile mode in headless Weston, like the frame-time test:
//   tool/perf.sh --target=integration_test/latency_test.dart
// Prints "LATENCY ..." lines and saves build/perf/latency-<date>.json.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:openmusic/main.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/player_controller.dart';
import 'package:openmusic/ui/widgets/shelf.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Popular, long-lived uploads on YouTube Music.
final _songs = [
  Track.youtube(videoId: 'E7kHvjvU6JY', title: 'Hati-Hati di Jalan', artist: 'Tulus'),
  Track.youtube(videoId: 'dQw4w9WgXcQ', title: 'Never Gonna Give You Up', artist: 'Rick Astley'),
  Track.youtube(videoId: 'kJQP7kiw5Fk', title: 'Despacito', artist: 'Luis Fonsi'),
  Track.youtube(videoId: 'fJ9rUzIMcZQ', title: 'Bohemian Rhapsody', artist: 'Queen'),
  Track.youtube(videoId: 'hTWKbfoikeg', title: 'Smells Like Teen Spirit', artist: 'Nirvana'),
  Track.youtube(videoId: 'YQHsXMglC9A', title: 'Hello', artist: 'Adele'),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('time until the music plays', (tester) async {
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('om-latency');
    addTearDown(() => dir.deleteSync(recursive: true));
    final flac = '${dir.path}/local.flac';
    final made = await Process.run('ffmpeg', [
      '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'sine=f=440:d=120', '-sample_fmt', 's16', flac, //
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');

    final results = <String, int>{};

    // ── Home: until YouTube Music's shelves are on screen, on a first launch
    // and on the next one (a new app, as after a restart) ──
    Future<void> home(String label) async {
      final app = PlayerController();
      await app.load();
      final sw = Stopwatch()..start();
      await tester.pumpWidget(OpenMusicApp(controller: app));
      while (find.byType(Shelf).evaluate().isEmpty) {
        if (sw.elapsed > const Duration(seconds: 30)) fail('$label: no shelves after 30 s');
        await tester.pump(const Duration(milliseconds: 5));
      }
      results[label] = sw.elapsedMilliseconds;
      debugPrint('LATENCY $label: ${sw.elapsedMilliseconds} ms');
      await tester.pump(const Duration(seconds: 3)); // let the fresh shelves land
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    }

    await home('Home: shelves on first launch');
    await home('Home: shelves on the next launch');

    final c = PlayerController();
    final apply = JustAudioMediaKit.onPlayerCreated!;
    JustAudioMediaKit.onPlayerCreated = (p) async {
      await (p.platform as NativePlayer).setProperty('ao', 'null');
      apply(p);
    };
    await c.load();
    await c.setAutoplay(false);

    /// Milliseconds from [action] until [index] plays past [past].
    Future<void> measure(String label, Future<void> Function() action, {int? index, Duration? past}) async {
      final sw = Stopwatch()..start();
      await action();
      final want = index ?? c.player.currentIndex;
      // mpv reports a seek's target at once; real playback is when the
      // position moves on past it, so count 200 ms of play and take it off.
      const played = Duration(milliseconds: 200);
      final from = past == null ? Duration.zero : past + played;
      while (!(c.player.playing && c.player.currentIndex == want && c.player.position > from)) {
        if (sw.elapsed > const Duration(seconds: 60)) fail('$label: still not playing after 60 s');
        await tester.pump(const Duration(milliseconds: 5));
      }
      final ms = sw.elapsedMilliseconds - (past == null ? 0 : played.inMilliseconds);
      results[label] = ms;
      debugPrint('LATENCY $label: $ms ms');
      // Let it play a moment, like a listener would before the next action.
      await tester.pump(const Duration(seconds: 2));
    }

    await measure('YouTube: first song after start', () => c.playList(_songs, 0), index: 0);
    await measure('YouTube: next song', c.next, index: 1);
    await measure('YouTube: next song again', c.next, index: 2);
    await measure('YouTube: jump to a song not looked up yet', () => c.playQueueItem(_songs[5]), index: 5);
    await measure(
      'YouTube: seek to 2:30',
      () => c.player.seek(const Duration(minutes: 2, seconds: 30)),
      past: const Duration(minutes: 2, seconds: 30),
    );
    await measure('Local FLAC: play', () => c.playList([Track.fromUri(Uri.file(flac))], 0), index: 0);
    await measure(
      'Local FLAC: seek to 1:30',
      () => c.player.seek(const Duration(minutes: 1, seconds: 30)),
      past: const Duration(minutes: 1, seconds: 30),
    );
    await c.player.stop();

    final out = Directory('build/perf')..createSync(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    File('${out.path}/latency-$stamp.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
