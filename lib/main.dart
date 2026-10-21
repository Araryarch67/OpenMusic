import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'services/appearance.dart';
import 'services/media_session.dart';
import 'services/player_controller.dart';
import 'ui/home_shell.dart';
import 'ui/player_panels.dart' show MiniPlayerWindow, fullScreenPlayer, miniPlayer;
import 'ui/theme.dart';
import 'ui/widgets/title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) await _logErrorsToFile();
  // just_audio has no native Linux/Windows backend; route those through libmpv.
  // Android too: libmpv gives it the equalizer, ReplayGain, gapless, the
  // signal path and decoders (ALAC, WavPack, DSD) that ExoPlayer lacks.
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true, android: true);
  await Appearance.instance.load();

  if (hasCustomTitleBar) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: 'OpenMusic',
        minimumSize: const Size(320, 420),
        // Linux: the window has an alpha channel; Flutter paints the background.
        backgroundColor: Platform.isLinux ? Colors.transparent : AppColors.background,
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
  await MediaSession.start(controller);
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

class OpenMusicApp extends StatefulWidget {
  const OpenMusicApp({super.key, required this.controller, this.theme});

  final PlayerController controller;

  /// Overridable so tests can render with a locally loaded font.
  final ThemeData? theme;

  @override
  State<OpenMusicApp> createState() => _OpenMusicAppState();
}

class _OpenMusicAppState extends State<OpenMusicApp> {
  final _appearance = Appearance.instance;

  @override
  void initState() {
    super.initState();
    _appearance.addListener(_restyle);
  }

  @override
  void dispose() {
    _appearance.removeListener(_restyle);
    super.dispose();
  }

  /// Widgets read [AppColors] directly rather than through an inherited
  /// widget, so a new accent or opacity repaints the whole tree (state kept).
  void _restyle() {
    setState(() {});
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) {
    // Decoded images: covers are decoded at their on-screen size, so 40 MiB
    // still holds a few hundred (Flutter's default is 100 MiB).
    PaintingBinding.instance.imageCache.maximumSizeBytes = 40 << 20;
    final theme = widget.theme ?? buildAppTheme();
    return PlayerScope(
      controller: widget.controller,
      child: MaterialApp(
        title: 'OpenMusic',
        debugShowCheckedModeBanner: false,
        // On desktop the frame paints the (maybe see-through) window
        // background once; pages on top mustn't stack a second layer.
        theme: hasCustomTitleBar ? theme.copyWith(scaffoldBackgroundColor: Colors.transparent) : theme,
        builder: (context, child) {
          final scaled = MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(MediaQuery.textScalerOf(context).scale(1) * _appearance.textScale),
            ),
            child: child!,
          );
          // The title bar sits above every route (including full-screen ones like Now Playing).
          return hasCustomTitleBar ? _DesktopFrame(child: scaled) : scaled;
        },
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
          // Hidden while the player fills the screen.
          ListenableBuilder(
            listenable: Listenable.merge([fullScreenPlayer, titleBarInShell]),
            builder: (context, bar) => fullScreenPlayer.value || titleBarInShell.value ? const SizedBox.shrink() : bar!,
            child: const AppTitleBar(),
          ),
          Expanded(
            child: MediaQuery.removePadding(context: context, removeTop: true, child: child),
          ),
        ],
      ),
    );
    // Mini player: the app stays alive (hidden) under it, so leaving it returns to the same page.
    final withMini = ValueListenableBuilder(
      valueListenable: miniPlayer,
      builder: (context, mini, app) => Stack(
        fit: StackFit.expand,
        children: [
          Offstage(offstage: mini, child: app),
          if (mini) const Material(type: MaterialType.transparency, child: MiniPlayerWindow()),
        ],
      ),
      child: frame,
    );
    return Platform.isLinux ? DragToResizeArea(resizeEdgeSize: 6, child: withMini) : withMini;
  }
}
