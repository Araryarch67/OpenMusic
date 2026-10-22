import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/main.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/player_controller.dart';
import 'package:openmusic/ui/player_panels.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lays the whole app out at many window and phone sizes and fails on any
/// "RenderFlex overflowed" (or other layout error).
void main() {
  late Directory music;
  setUpAll(() {
    music = Directory.systemTemp.createTempSync('openmusic-overflow');
    for (final name in ['Jairo - Paradise', 'Codfish - Boots', 'D-low - Poison Dagger', 'Osis - Rise']) {
      File('${music.path}/$name.flac').writeAsBytesSync(const []);
    }
  });
  tearDownAll(() => music.deleteSync(recursive: true));

  Future<void> layOut(
    WidgetTester tester,
    Size size, {
    double dpr = 1,
    EdgeInsets insets = EdgeInsets.zero,
    bool? desktopBar,
  }) async {
    SharedPreferences.setMockInitialValues({
      'library.v1': jsonEncode([for (final f in music.listSync()) Track.fromUri(Uri.file(f.path)).toJson()]),
    });
    final c = PlayerController();
    await tester.runAsync(c.load);
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = tester.view.viewPadding = FakeViewPadding(
      left: insets.left * dpr,
      top: insets.top * dpr,
      right: insets.right * dpr,
      bottom: insets.bottom * dpr,
    );
    final errors = <String>[];
    final orig = FlutterError.onError;
    FlutterError.onError = (d) {
      final s = d.toString();
      // Fonts and plugins aren't there in tests; only layout errors count.
      if (!s.contains('google_fonts') && !s.contains('GoogleFonts') && !s.contains('MissingPlugin')) {
        errors.add(s.split('\n').where((l) => l.contains('overflowed') || l.contains('file:///')).take(4).join('\n'));
      }
    };
    try {
      await tester.pumpWidget(OpenMusicApp(controller: c));
      await tester.pump(const Duration(milliseconds: 500));
      if (desktopBar != null) expect(find.byType(DesktopPlayerBar), desktopBar ? findsOneWidget : findsNothing);
    } finally {
      FlutterError.onError = orig;
      tester.view.reset();
    }
    expect(errors, isEmpty, reason: 'layout errors at $size');
  }

  for (final w in const <double>[240, 320, 600, 699, 700, 768, 1024, 1199, 1200, 1920]) {
    for (final h in const <double>[240, 320, 360, 439, 440, 600]) {
      // Desktop windows (tests default to Android): the desktop layout from 700 wide, however short.
      testWidgets('window ${w.toInt()}x${h.toInt()}', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          await layOut(tester, Size(w, h), desktopBar: w >= 700);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  // Phones (Android) upright and sideways, with the status bar, gesture bar
  // and a camera cutout on either side.
  for (final (w, h) in [(360.0, 640.0), (375.0, 817.0), (412.0, 915.0)]) {
    for (final sideways in [false, true]) {
      final size = sideways ? Size(h, w) : Size(w, h);
      // Sideways it keeps the phone layout (tabs in a rail), not the desktop one.
      testWidgets('phone ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await layOut(
            tester,
            size,
            dpr: 3,
            insets: sideways ? const EdgeInsets.fromLTRB(40, 28, 0, 16) : const EdgeInsets.only(top: 40, bottom: 16),
            desktopBar: false,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}
