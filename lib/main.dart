import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'services/player_controller.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';
import 'ui/widgets/title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) await _logErrorsToFile();
  // just_audio has no native Linux/Windows backend; route those through libmpv.
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);

  if (hasCustomTitleBar) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'OpenMusic',
        minimumSize: Size(320, 420),
        backgroundColor: AppColors.background,
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  final controller = PlayerController();
  await controller.load();
  runApp(OpenMusicApp(controller: controller));
}

/// Debug builds: also append every framework error (with full stack) to
/// `<app support>/errors.log`. The terminal only shows the first error in full and
/// collapses repeats to "Another exception was thrown", which hides the cause.
Future<void> _logErrorsToFile() async {
  final file = File(p.join((await getApplicationSupportDirectory()).path, 'errors.log'));
  await file.parent.create(recursive: true);
  if (file.existsSync() && file.lengthSync() > 2 << 20) await file.writeAsString('');
  final sink = file.openWrite(mode: FileMode.append)..writeln('\n===== run ${DateTime.now()} =====');
  var logged = 0;
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (logged++ < 50) sink.writeln('--- ${DateTime.now()}\n${details.toString()}\n${details.stack}');
    previous?.call(details);
  };
}

class OpenMusicApp extends StatelessWidget {
  const OpenMusicApp({super.key, required this.controller, this.theme});

  final PlayerController controller;

  /// Overridable so tests can render with a locally loaded font.
  final ThemeData? theme;

  @override
  Widget build(BuildContext context) {
    return PlayerScope(
      controller: controller,
      child: MaterialApp(
        title: 'OpenMusic',
        debugShowCheckedModeBanner: false,
        theme: theme ?? buildAppTheme(),
        // The title bar sits above every route (including full-screen ones like Now Playing).
        builder: hasCustomTitleBar ? (context, child) => _DesktopFrame(child: child!) : null,
        home: const HomeShell(),
      ),
    );
  }
}

/// Custom title bar on top; on Linux also invisible resize edges, since the
/// window has no native frame there (tiling WMs simply ignore them).
class _DesktopFrame extends StatelessWidget {
  const _DesktopFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final frame = ColoredBox(
      color: AppColors.background,
      child: Column(
        children: [
          const AppTitleBar(),
          Expanded(
            child: MediaQuery.removePadding(context: context, removeTop: true, child: child),
          ),
        ],
      ),
    );
    return Platform.isLinux ? DragToResizeArea(resizeEdgeSize: 6, child: frame) : frame;
  }
}
