// Takes the screenshots in docs/screenshots for the README.
//
//   env -u DISPLAY WAYLAND_DISPLAY=om-test GDK_BACKEND=wayland XDG_DATA_HOME=/tmp/om-shots-data \
//     flutter test integration_test/readme_screenshots_test.dart -d linux --dart-define=SHOTS=/tmp/om-shots
//
// Signed out (public YouTube Music only) and with a throwaway data dir, so no
// personal library ends up in a picture. Does nothing without SHOTS.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:openmusic/main.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/player_controller.dart';
import 'package:openmusic/ui/player_panels.dart';
import 'package:openmusic/ui/widgets/signal_path.dart';
import 'package:shared_preferences/shared_preferences.dart';

const shots = String.fromEnvironment('SHOTS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('README screenshots', (tester) async {
    if (shots.isEmpty) return;
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
    Directory(shots).createSync(recursive: true);

    // A silent 24-bit / 96 kHz FLAC, for the signal path picture.
    final dir = Directory.systemTemp.createTempSync('om-shots');
    final flac = '${dir.path}/Studio Session.flac';
    await Process.run('ffmpeg', [
      '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'anullsrc=r=96000:cl=stereo', '-t', '600', //
      '-sample_fmt', 's32', '-metadata', 'title=Studio Session', '-metadata', 'artist=OpenMusic',
      '-metadata', 'album=Hi-Res Test', '-c:a', 'flac', flac,
    ]);
    // Played directly, not added to the library, so Home stays about real music.
    final studio = Track(
      id: Uri.file(flac).toString(),
      uri: Uri.file(flac),
      title: 'Studio Session',
      artist: 'OpenMusic',
      album: 'Hi-Res Test',
    );
    SharedPreferences.setMockInitialValues({});

    final c = PlayerController();
    await c.load();
    await c.player.setVolume(0);

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(RepaintBoundary(child: OpenMusicApp(controller: c)));

    Future<void> settle([int ms = 600]) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<bool> until(bool Function() ok, {int seconds = 30}) async {
      for (var i = 0; i < seconds * 10; i++) {
        if (ok()) return true;
        await tester.pump(const Duration(milliseconds: 100));
      }
      return ok();
    }

    Future<void> shot(String name) async {
      await settle(2500); // artwork and colours fade in
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        return image.toByteData(format: ui.ImageByteFormat.png);
      });
      File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    Future<void> playing() async {
      await until(() => c.player.playing && c.player.position > Duration.zero, seconds: 45);
    }

    Future<List<Track>> search(String q) async => (await tester.runAsync(() => c.searchYoutube(q)))!;

    try {
      await until(() => find.text('Quick picks').evaluate().isNotEmpty || find.text('Trending').evaluate().isNotEmpty);

      // Home with a D-low song playing.
      final dlow = await search('D-low beatbox');
      final codfish = await search('codfish beatbox');
      c.createPlaylist('Beatbox mix', tracks: [...dlow.take(4), ...codfish.take(4)]);
      await c.playList(codfish, 1, from: 'Codfish');
      await playing();
      await c.playList(dlow, 0, from: 'D-low');
      await playing();
      await shot('home');

      // Search: your music and YouTube Music together.
      await tester.tap(find.text('Search').first);
      await settle();
      await tester.enterText(find.byType(TextField).first, 'codfish');
      // Enter: the suggestions close and the results (top result, songs, artists…) show.
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await until(() => find.text('Top result').evaluate().isNotEmpty);
      await shot('search');

      // An OpenMusic playlist mixing artists.
      await tester.tap(find.text('Beatbox mix').first);
      await settle();
      await tester.tap(find.byTooltip('Shuffle play'));
      await playing();
      await shot('playlist');

      // Synced lyrics.
      final sung = await search('hindia evaluasi');
      await c.playList(sung, 0, from: 'Search');
      await playing();
      await c.player.seek(const Duration(seconds: 48));
      await tester.tap(find.byTooltip('Lyrics'));
      await until(() => find.text('Lyrics from LRCLIB').evaluate().isNotEmpty);
      await shot('lyrics');

      // Settings, then the equalizer.
      await tester.tap(find.text('Settings').first);
      await shot('settings');
      await tester.tap(find.text('Equalizer'));
      await settle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Bass boost'));
      await shot('equalizer');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Flat'));
      await tester.tap(find.byType(Switch).first); // equalizer off again
      await settle();

      // Signal path of the hi-res file.
      await tester.tap(find.text('Home').first);
      await settle();
      await c.playList([studio], 0, from: 'Hi-Res Test');
      await c.player.setVolume(1);
      await playing();
      await until(() => find.textContaining('FLAC').evaluate().isNotEmpty);
      showSignalPath(tester.element(find.byType(QualityBadge).first)).ignore();
      await until(() => find.text('Decoded').evaluate().isNotEmpty);
      await shot('signal-path');
      await tester.tapAt(const Offset(700, 150));
      await settle();
      await c.player.setVolume(0);

      // Desktop full-screen player.
      await c.playList(dlow, 0, from: 'D-low');
      await playing();
      await tester.tap(find.byTooltip('Full screen'));
      await settle(4000); // past the "Press Esc" hint
      await shot('fullscreen');
      await tester.tap(find.byTooltip('Exit full screen').first);
      await settle();

      // Phone: full-screen player.
      await c.playList(codfish, 0, from: 'Codfish');
      await playing();
      tester.view.physicalSize = const Size(400, 860);
      await settle(1000);
      await tester.tap(find.byType(MiniPlayer));
      await shot('phone');
    } finally {
      await c.player.stop();
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
