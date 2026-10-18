import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/main.dart';
import 'package:openmusic/services/player_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Ctrl+V and Space reach text fields instead of app shortcuts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? clipboard = 'pasted-client-id.apps.googleusercontent.com';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });

    await tester.pumpWidget(OpenMusicApp(controller: PlayerController()));
    await tester.pump();
    await tester.tap(find.text('Search').first);
    await tester.pump(const Duration(milliseconds: 400));
    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    // Not handled by the app => it falls through to the text field's input instead of toggling playback.
    final spaceHandled = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(spaceHandled, isFalse);

    final text = tester.widget<TextField>(field).controller!.text;
    expect(text, startsWith('pasted-client-id'));
    clipboard = null;

    // Outside a text field the shortcut still works.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.space), isTrue);
  });
}
