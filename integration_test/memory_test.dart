// Memory use at fixed points: idle, playing a local song, streaming YouTube,
// after scrolling. Run in profile mode (debug builds carry the JIT and use far
// more memory), one fresh process per run:
//   tool/memory.sh            (prints MEM lines, saves build/perf/memory-<date>.json)
//
// Reads /proc/self/smaps_rollup where the OS has it (Linux, Android) for PSS
// (shared pages split between the processes using them) and private memory;
// RSS comes from dart:io everywhere.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

Future<void> _ffmpeg(List<String> args) async {
  final r = await Process.run('ffmpeg', ['-loglevel', 'error', '-y', ...args]);
  if (r.exitCode != 0) throw StateError('ffmpeg: ${r.stderr}');
}

/// Memory of this process in MiB: rss always, pss / private where the OS reports them.
Map<String, double> _memory() {
  double mib(int kb) => kb / 1024;
  final out = <String, double>{'rss': ProcessInfo.currentRss / (1 << 20)};
  final rollup = File('/proc/self/smaps_rollup');
  if (rollup.existsSync()) {
    int field(String name) =>
        int.tryParse(RegExp('^$name:\\s+(\\d+) kB', multiLine: true).firstMatch(rollup.readAsStringSync())?[1] ?? '') ??
        0;
    out['pss'] = mib(field('Pss'));
    out['private'] = mib(field('Private_Clean') + field('Private_Dirty'));
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('memory at fixed points', (tester) async {
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true, android: true);

    // The same 12 albums × 10 songs (real covers) as the performance test.
    final dir = Directory.systemTemp.createTempSync('om-mem');
    addTearDown(() => dir.deleteSync(recursive: true));
    final files = <String>[];
    for (var a = 1; a <= 12; a++) {
      final cover = '${dir.path}/cover$a.jpg';
      await _ffmpeg(['-f', 'lavfi', '-i', 'color=c=0x${(a * 20).toRadixString(16).padLeft(2, '0')}4080:s=1000x1000', '-frames:v', '1', cover]);
      await Future.wait([
        for (var t = 1; t <= 10; t++)
          () async {
            final f = '${dir.path}/a${a}_t$t.flac';
            await _ffmpeg([
              '-f', 'lavfi', '-i', 'sine=f=${200 + t * 30}:d=60', '-i', cover, '-map', '0', '-map', '1', //
              '-c:v', 'mjpeg', '-disposition:v', 'attached_pic',
              '-metadata', 'title=Song $t of album $a', '-metadata', 'artist=Artist ${a % 5}',
              '-metadata', 'album=Album $a', '-metadata', 'track=$t', f,
            ]);
            files.add(f);
          }(),
      ]);
    }
    // Plus one long hi-res song that doesn't compress away (noise, not a sine),
    // so mpv's read-ahead buffer fills the way it does with real music.
    final hires = '${dir.path}/a0_hires.flac';
    await _ffmpeg([
      '-f', 'lavfi', '-i', 'anoisesrc=c=pink:a=0.3:d=240:r=96000', '-ac', '2', '-sample_fmt', 's32', //
      '-metadata', 'title=Hi-res song', '-metadata', 'artist=Artist 0', '-metadata', 'album=Album 0', hires,
    ]);
    files.add(hires);
    SharedPreferences.setMockInitialValues({
      'library.v1': jsonEncode([for (final f in files..sort()) Track.fromUri(Uri.file(f)).toJson()]),
    });

    // Silent output, so the run doesn't play through the speakers.
    final c = PlayerController();
    final apply = JustAudioMediaKit.onPlayerCreated!;
    JustAudioMediaKit.onPlayerCreated = (p) async {
      await (p.platform as NativePlayer).setProperty('ao', 'null');
      apply(p);
    };
    await c.load();
    while (c.scanning) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 1.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(OpenMusicApp(controller: c));

    Future<void> run(Duration d) async {
      final sw = Stopwatch()..start();
      while (sw.elapsed < d) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    final results = <String, Map<String, double>>{};
    Future<void> sample(String label) async {
      await run(const Duration(seconds: 2));
      results[label] = _memory();
      debugPrint('MEM $label: ${results[label]!.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(1)} MiB').join(', ')}');
    }

    await run(const Duration(seconds: 8)); // covers decoded, home settled
    await sample('idle');

    final songs = c.allSongs;
    await c.playCollection(songs, index: songs.tracks.indexWhere((t) => t.path == hires));
    await run(const Duration(seconds: 15));
    await sample('playing 24/96 FLAC');

    final yt = await tester.runAsync(() => c.searchYoutube('codfish beatbox'));
    if (yt != null && yt.isNotEmpty) {
      await c.playList(yt, 0, from: 'Memory test');
      final sw = Stopwatch()..start();
      while (!(c.player.playing && c.player.position > const Duration(seconds: 2)) && sw.elapsed.inSeconds < 40) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await run(const Duration(seconds: 15));
      await sample('streaming YouTube');
    }

    ShellScope.of(tester.element(find.byType(PageScaffold).first)).openCollection(c.allSongs);
    await run(const Duration(seconds: 1));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(860, 450)));
    for (var i = 0; i < 80; i++) {
      await tester.sendEventToBinding(pointer.scroll(Offset(0, i < 40 ? 160 : -160)));
      await run(const Duration(milliseconds: 48));
    }
    await sample('after scrolling 120 songs');
    await c.player.stop();

    final out = File('build/perf/memory-${DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-')}.json');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'os': Platform.operatingSystem,
        'mode': kProfileMode ? 'profile' : 'debug',
        ...results,
      }),
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
