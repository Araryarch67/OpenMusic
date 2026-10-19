// Performance budget: is the app getting slower?
//
// Plays a song from a generated 120-song library (real cover art) and measures
// frame build times while the app sits idle and while the mouse wheel scrolls
// Home and All Songs. Also counts how often the whole app is told to rebuild.
//
// Run it in profile mode (debug-mode timings mean nothing), in headless Weston:
//   tool/perf.sh
// Results go to build/perf/<date>.json so runs can be compared over time.
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

/// Budgets, in profile mode. A frame has 16.7 ms at 60 Hz; build is only part of it.
const _buildP90Ms = 8.0;
const _buildMaxMs = 40.0;

/// While a song plays and nothing else happens, app-wide rebuilds per second.
const _idleNotifiesPerSecond = 2.0;

Future<void> _ffmpeg(List<String> args) async {
  final r = await Process.run('ffmpeg', ['-loglevel', 'error', '-y', ...args]);
  if (r.exitCode != 0) throw StateError('ffmpeg: ${r.stderr}');
}

class _Result {
  _Result(this.label, this.frames, this.ms, this.build, this.notifies);

  final String label;
  final int frames;
  final int ms;
  final List<double> build;
  final int notifies;

  double pct(double p) => build.isEmpty ? 0 : build[((build.length - 1) * p).round()];

  Map<String, Object> toJson() => {
    'frames': frames,
    'ms': ms,
    'buildP50': pct(.5),
    'buildP90': pct(.9),
    'buildMax': pct(1),
    'notifies': notifies,
  };

  @override
  String toString() =>
      '$label: $frames frames in $ms ms, build p50 ${pct(.5).toStringAsFixed(1)} '
      'p90 ${pct(.9).toStringAsFixed(1)} max ${pct(1).toStringAsFixed(1)} ms, app rebuilds $notifies';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scrolling and playback stay within the frame budget', (tester) async {
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true);

    // ── 12 albums × 10 songs, each album with its own 1000 px cover ──
    final dir = Directory.systemTemp.createTempSync('om-perf');
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
              '-f', 'lavfi', '-i', 'sine=f=${200 + t * 30}:d=20', '-i', cover, '-map', '0', '-map', '1', //
              '-c:v', 'mjpeg', '-disposition:v', 'attached_pic',
              '-metadata', 'title=Song $t of album $a', '-metadata', 'artist=Artist ${a % 5}',
              '-metadata', 'album=Album $a', '-metadata', 'track=$t', f,
            ]);
            files.add(f);
          }(),
      ]);
    }
    SharedPreferences.setMockInitialValues({
      'library.v1': jsonEncode([for (final f in files..sort()) Track.fromUri(Uri.file(f)).toJson()]),
    });

    // Silent output: every player mpv creates gets the null output first.
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
    // A 2560x1600 laptop panel at 160% scale.
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 1.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(OpenMusicApp(controller: c));
    await c.playCollection(c.allSongs);

    var notifies = 0;
    c.addListener(() => notifies++);
    final timings = <FrameTiming>[];
    SchedulerBinding.instance.addTimingsCallback(timings.addAll);

    Future<void> run(Duration d) async {
      final sw = Stopwatch()..start();
      while (sw.elapsed < d) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    // Warm up: covers decoded, accent colours computed, song playing.
    await run(const Duration(seconds: 3));

    final results = <_Result>[];
    Future<_Result> measure(String label, Future<void> Function() body) async {
      await run(const Duration(milliseconds: 500));
      timings.clear();
      notifies = 0;
      final sw = Stopwatch()..start();
      await body();
      await run(const Duration(milliseconds: 300));
      final r = _Result(
        label,
        timings.length,
        sw.elapsedMilliseconds,
        [for (final t in timings) t.buildDuration.inMicroseconds / 1000]..sort(),
        notifies,
      );
      results.add(r);
      debugPrint('PERF $r');
      return r;
    }

    /// Wheel-scrolls whatever is under [at]: down for half the ticks, then back up.
    Future<void> wheel({Offset at = const Offset(860, 450), int ticks = 40}) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(at));
      for (var i = 0; i < ticks; i++) {
        await tester.sendEventToBinding(pointer.scroll(Offset(0, i < ticks / 2 ? 120 : -120)));
        await run(const Duration(milliseconds: 48));
      }
    }

    Future<void> open(Finder target) async {
      await tester.tap(target.first, warnIfMissed: false);
      await run(const Duration(milliseconds: 1200));
    }

    /// Opens a collection the way the app does, wherever its link happens to be.
    Future<void> openCollection(Collection col) async {
      ShellScope.of(tester.element(find.byType(PageScaffold).first)).openCollection(col);
      await run(const Duration(milliseconds: 1200));
    }

    final idle = await measure('idle while playing', () => run(const Duration(seconds: 3)));
    await measure('wheel scroll Home', wheel);
    await measure('wheel scroll sidebar library', () => wheel(at: const Offset(150, 650)));
    await openCollection(c.allSongs);
    await measure('wheel scroll All Songs', () => wheel(ticks: 60));
    await openCollection(c.albums[2]);
    await measure('wheel scroll album', wheel);
    await openCollection(c.artists[1]);
    await measure('wheel scroll artist', wheel);
    await open(find.text('Search'));
    await tester.enterText(find.byType(TextField).first, 'Song');
    await run(const Duration(milliseconds: 800));
    FocusManager.instance.primaryFocus?.unfocus(); // closes the suggestions
    await run(const Duration(milliseconds: 300));
    await measure('wheel scroll search results', wheel);
    await open(find.byTooltip('Queue'));
    await measure('wheel scroll queue', wheel);
    await open(find.text('Downloads'));
    await measure('wheel scroll downloads', wheel);
    await open(find.text('Settings'));
    await measure('wheel scroll settings', wheel);
    // Linux desktops with an accessibility bus (AT-SPI) turn Flutter's semantics
    // tree on, which every scrolled frame then has to update too.
    await openCollection(c.allSongs);
    final semantics = tester.ensureSemantics();
    await run(const Duration(milliseconds: 500));
    await measure('wheel scroll All Songs (accessibility on)', () => wheel(ticks: 60));
    semantics.dispose();
    await c.player.stop();

    final out = File('build/perf/${DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-')}.json');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'mode': kProfileMode ? 'profile' : 'debug',
        for (final r in results) r.label: r.toJson(),
      }),
    );

    expect(
      idle.notifies / (idle.ms / 1000),
      lessThanOrEqualTo(_idleNotifiesPerSecond),
      reason: 'the whole app rebuilds too often while a song just plays',
    );
    if (!kProfileMode) return markTestSkipped('frame budgets are only checked in profile mode');
    for (final r in results) {
      expect(r.pct(.9), lessThanOrEqualTo(_buildP90Ms), reason: '${r.label}: 90th percentile frame build');
      expect(r.pct(1), lessThanOrEqualTo(_buildMaxMs), reason: '${r.label}: slowest frame build');
    }
  });
}
