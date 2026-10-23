// Performance with a big library: what grows with the number of songs.
//
// 8000 songs known only by their tags (an audiophile's library is often this
// big) plus 240 real FLAC files with 1000 px covers. Measures how long the
// library takes to load and to scan, how long the UI isolate stalls and how
// long frames take to build when a song changes, on play / pause and while
// Home, the sidebar and All Songs scroll; then the process's memory.
//
// Uses the real SharedPreferences (in the throwaway XDG_DATA_HOME of
// tool/perf.sh), so saving costs what it costs on a user's machine. Profile
// mode, headless Weston:
//   tool/perf.sh --target=integration_test/big_library_test.dart
// Prints "BIG ..." lines and saves build/perf/big-<date>.json.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

const _taggedOnly = 8000;
const _albums = 12, _perAlbum = 20;

Future<void> _ffmpeg(List<String> args) async {
  final r = await Process.run('ffmpeg', ['-loglevel', 'error', '-y', ...args]);
  if (r.exitCode != 0) throw StateError('ffmpeg: ${r.stderr}');
}

Map<String, double> _memory() {
  double mib(int kb) => kb / 1024;
  final out = <String, double>{'rss': ProcessInfo.currentRss / (1 << 20)};
  final rollup = File('/proc/self/smaps_rollup');
  if (rollup.existsSync()) {
    final text = rollup.readAsStringSync();
    int field(String name) =>
        int.tryParse(RegExp('^$name:\\s+(\\d+) kB', multiLine: true).firstMatch(text)?[1] ?? '') ?? 0;
    out['pss'] = mib(field('Pss'));
    out['private'] = mib(field('Private_Clean') + field('Private_Dirty'));
  }
  return out;
}

/// The longest the event loop went without running a 2 ms timer: work that
/// blocks the UI isolate (frames or not) shows up here.
class _StallMeter {
  Timer? _timer;
  final _clock = Stopwatch();
  int _last = 0;
  int worst = 0;

  void start() {
    worst = 0;
    _clock
      ..reset()
      ..start();
    _last = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
      final now = _clock.elapsedMicroseconds;
      if (now - _last > worst) worst = now - _last;
      _last = now;
    });
  }

  double stop() {
    _timer?.cancel();
    final now = _clock.elapsedMicroseconds;
    if (now - _last > worst) worst = now - _last;
    return worst / 1000;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a big library stays fast', (tester) async {
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
    final results = <String, Object>{'mode': kProfileMode ? 'profile' : 'debug'};
    void report(String label, Object value) {
      results[label] = value;
      debugPrint('BIG $label: $value');
    }

    // ── 240 real files: 12 albums × 20 songs, each album with its own cover ──
    final dir = Directory.systemTemp.createTempSync('om-big');
    addTearDown(() => dir.deleteSync(recursive: true));
    final files = <String>[];
    for (var a = 1; a <= _albums; a++) {
      final cover = '${dir.path}/cover$a.jpg';
      await _ffmpeg([
        '-f',
        'lavfi',
        '-i',
        'color=c=0x${(a * 20).toRadixString(16).padLeft(2, '0')}4080:s=1000x1000',
        '-frames:v',
        '1',
        cover,
      ]);
      await Future.wait([
        for (var t = 1; t <= _perAlbum; t++)
          () async {
            final f = '${dir.path}/a${a}_t$t.flac';
            await _ffmpeg([
              '-f', 'lavfi', '-i', 'sine=f=${200 + t * 30}:d=8', '-i', cover, '-map', '0', '-map', '1', //
              '-c:v', 'mjpeg', '-disposition:v', 'attached_pic',
              '-metadata', 'title=Real song $t of album $a', '-metadata', 'artist=Real artist ${a % 5}',
              '-metadata', 'album=Real album $a', '-metadata', 'track=$t', f,
            ]);
            files.add(f);
          }(),
      ]);
    }
    files.sort();

    // ── 8000 more, already tagged (their files don't exist: only the UI sees them) ──
    final tagged = [
      for (var i = 0; i < _taggedOnly; i++)
        Track(
          id: Uri.file('/nonexistent/album${i ~/ 10}/${i % 10 + 1} Song $i.flac').toString(),
          uri: Uri.file('/nonexistent/album${i ~/ 10}/${i % 10 + 1} Song $i.flac'),
          title: 'Song $i ${['Blue', 'Night', 'Rain', 'Light', 'Fire'][i % 5]}',
          artist: 'Artist ${(i ~/ 10) % 400}',
          album: 'Album ${i ~/ 10}',
          duration: Duration(seconds: 150 + i % 120),
          trackNumber: i % 10 + 1,
          addedAt: i,
          tagged: true,
        ),
    ];

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await prefs.setString(
      'library.v1',
      jsonEncode([for (final t in tagged) t.toJson(), for (final f in files) Track.fromUri(Uri.file(f)).toJson()]),
    );

    // Silent: every player mpv creates gets the null output first. (Each
    // controller's audio engine installs its own hook, so wrap it each time.)
    PlayerController silent() {
      final c = PlayerController();
      final apply = JustAudioMediaKit.onPlayerCreated!;
      JustAudioMediaKit.onPlayerCreated = (p) async {
        await (p.platform as NativePlayer).setProperty('ao', 'null');
        apply(p);
      };
      return c;
    }

    // ── First launch: load, then scan the 240 untagged files ──
    var sw = Stopwatch()..start();
    final first = silent();
    await first.load();
    report('load (first launch) ms', sw.elapsedMilliseconds);
    sw = Stopwatch()..start();
    while (first.scanning) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    report('scan 240 files ms', sw.elapsedMilliseconds);
    await tester.pump(const Duration(seconds: 1)); // saves settle
    first.dispose();

    // ── Next launch: what a restart reads ──
    sw = Stopwatch()..start();
    await prefs.reload();
    final c = silent();
    await c.load();
    report('load (next launch) ms', sw.elapsedMilliseconds);
    expect(c.library.length, _taggedOnly + files.length);

    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 1.6;
    addTearDown(tester.view.reset);
    sw = Stopwatch()..start();
    await tester.pumpWidget(OpenMusicApp(controller: c));
    report('first frame ms', sw.elapsedMilliseconds);
    final real = [
      for (final t in c.library)
        if (t.path?.startsWith(dir.path) ?? false) t,
    ];
    await c.playList(real, 0, from: 'Real songs');

    final timings = <FrameTiming>[];
    SchedulerBinding.instance.addTimingsCallback(timings.addAll);
    Future<void> run(Duration d) async {
      final clock = Stopwatch()..start();
      while (clock.elapsed < d) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await run(const Duration(seconds: 3)); // covers decoded, song playing

    final stalls = _StallMeter();
    Future<void> measure(String label, Future<void> Function() body) async {
      await run(const Duration(milliseconds: 400));
      timings.clear();
      stalls.start();
      await body();
      await run(const Duration(milliseconds: 300));
      final stall = stalls.stop();
      final build = [for (final t in timings) t.buildDuration.inMicroseconds / 1000]..sort();
      double pct(double p) => build.isEmpty ? 0 : build[((build.length - 1) * p).round()];
      report(label, {
        'frames': build.length,
        'buildP50': double.parse(pct(.5).toStringAsFixed(2)),
        'buildP90': double.parse(pct(.9).toStringAsFixed(2)),
        'buildMax': double.parse(pct(1).toStringAsFixed(2)),
        'stallMax': double.parse(stall.toStringAsFixed(2)),
      });
    }

    Future<void> wheel({Offset at = const Offset(860, 450), int ticks = 40}) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(at));
      for (var i = 0; i < ticks; i++) {
        await tester.sendEventToBinding(pointer.scroll(Offset(0, i < ticks / 2 ? 120 : -120)));
        await run(const Duration(milliseconds: 48));
      }
    }

    await measure('idle while playing', () => run(const Duration(seconds: 3)));
    await measure('song changes x10', () async {
      for (var i = 0; i < 10; i++) {
        await c.next();
        await run(const Duration(milliseconds: 500));
      }
    });
    await measure('play/pause x10', () async {
      for (var i = 0; i < 10; i++) {
        await c.togglePlay();
        await run(const Duration(milliseconds: 250));
      }
    });
    await measure('wheel scroll Home', wheel);
    await measure('wheel scroll sidebar library', () => wheel(at: const Offset(150, 650)));
    await measure('open All Songs', () async {
      ShellScope.of(tester.element(find.byType(PageScaffold).first)).openCollection(c.allSongs);
      await run(const Duration(milliseconds: 1200));
    });
    await measure('wheel scroll All Songs', () => wheel(ticks: 60));
    await measure('song changes on All Songs x10', () async {
      for (var i = 0; i < 10; i++) {
        await c.next();
        await run(const Duration(milliseconds: 500));
      }
    });
    report('memory MiB', {for (final e in _memory().entries) e.key: double.parse(e.value.toStringAsFixed(1))});
    await c.player.stop();

    final out = File('build/perf/big-${DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-')}.json');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  });
}
