import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../models/track.dart';
import '../services/appearance.dart';
import '../services/audio_engine.dart';
import '../services/player_controller.dart';
import 'shell_scope.dart';
import 'theme.dart';
import 'widgets/controls.dart';
import 'widgets/signal_path.dart';
import 'pages/lyrics_page.dart';
import 'ytmusic_edit.dart';
import 'widgets/track_row.dart';
import 'widgets/smooth_scroll.dart';

/// Floating bar above the bottom tabs on phones, tinted with the cover colour.
/// Swipe sideways to change song, down to close; long-press for more.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  /// How far the song is being dragged sideways.
  final _drag = ValueNotifier<double>(0);

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _endDrag(PlayerController c, DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final dx = _drag.value;
    _drag.value = 0;
    if (dx < -72 || v < -600) {
      c.next();
    } else if (dx > 72 || v > 600) {
      c.previous();
    }
  }

  void _more(BuildContext context, PlayerController c) {
    final shell = ShellScope.of(context);
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: AppColors.elevated,
      showDragHandle: true,
      builder: (sheet) {
        Widget item(IconData icon, String label, VoidCallback onTap) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          onTap: () {
            Navigator.of(sheet).pop();
            onTap();
          },
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              item(Icons.queue_music_rounded, 'Queue', shell.openQueue),
              item(Icons.lyrics_outlined, 'Lyrics', shell.openLyrics),
              if (AudioEngine.supported) item(Icons.graphic_eq_rounded, 'Signal path', () => showSignalPath(context)),
              item(Icons.close_rounded, 'Close player', c.closePlayer),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final track = c.currentTrack;
    if (track == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return AccentBuilder(
      track: track,
      builder: (context, accent) => Dismissible(
        key: const ValueKey('mini-player'),
        direction: DismissDirection.down,
        onDismissed: (_) => c.closePlayer(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: GlassPanel(
            color: Color.lerp(accent, Colors.black, 0.45)!,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: widget.onOpen,
              onLongPress: () => _more(context, c),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 2, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragUpdate: (d) => _drag.value += d.delta.dx,
                            onHorizontalDragEnd: (d) => _endDrag(c, d),
                            onHorizontalDragCancel: () => _drag.value = 0,
                            child: ValueListenableBuilder<double>(
                              valueListenable: _drag,
                              builder: (context, dx, child) => Transform.translate(
                                offset: Offset(dx, 0),
                                child: Opacity(opacity: (1 - dx.abs() / 240).clamp(0.3, 1), child: child),
                              ),
                              child: _TrackSwitcher(
                                trackId: track.id,
                                slide: false,
                                child: Row(
                                  key: ValueKey(track.id),
                                  children: [
                                    Hero(
                                      tag: 'now-playing-art',
                                      child: Artwork(track: track, size: 40, radius: 4),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            track.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                                          ),
                                          Text(
                                            track.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: text.bodySmall?.copyWith(color: Colors.white70),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        LikeButton(track: track, size: 24, color: Colors.white),
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: c.isBuffering
                              ? const Center(
                                  child: SizedBox.square(
                                    dimension: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                                  ),
                                )
                              : IconButton(
                                  tooltip: c.isPlaying ? 'Pause' : 'Play',
                                  color: Colors.white,
                                  iconSize: 30,
                                  padding: EdgeInsets.zero,
                                  onPressed: c.togglePlay,
                                  icon: Icon(c.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                ),
                        ),
                        IconButton(
                          tooltip: 'Next',
                          color: Colors.white,
                          iconSize: 26,
                          onPressed: c.player.hasNext ? c.next : null,
                          icon: const Icon(Icons.skip_next_rounded),
                        ),
                      ],
                    ),
                  ),
                  _MiniProgress(
                    builder: (context, snap) {
                      final total = c.player.duration?.inMilliseconds ?? 0;
                      final pos = snap.data?.inMilliseconds ?? 0;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: LinearProgressIndicator(
                          value: total == 0 ? 0 : (pos / total).clamp(0, 1),
                          minHeight: 2,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-width bottom player bar for tablets and desktops.
class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar({super.key, required this.sidePanelOpen, required this.onToggleSidePanel});

  final bool sidePanelOpen;

  /// Null when the window is too narrow for the side panel.
  final VoidCallback? onToggleSidePanel;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final track = c.currentTrack;
    return SizedBox(
      height: 80,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 20, 0),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: _TrackSwitcher(
                trackId: track?.id,
                child: track == null
                    ? const SizedBox.shrink()
                    : Row(
                        key: ValueKey(track.id),
                        children: [
                          Artwork(track: track, size: 56),
                          const SizedBox(width: 14),
                          Flexible(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _LinkText(
                                  track.title,
                                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                  onTap: switch (c.albumOf(track)) {
                                    final album? => () => shell.openCollection(album),
                                    null => null,
                                  },
                                ),
                                const SizedBox(height: 2),
                                _LinkText(
                                  track.artist,
                                  style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                                  onTap: switch (c.artistNamed(track.artist)) {
                                    final artist? => () => shell.openCollection(artist),
                                    null => null,
                                  },
                                ),
                              ],
                            ),
                          ),
                          LikeButton(track: track),
                          DownloadButton(track: track),
                        ],
                      ),
              ),
            ),
            Expanded(
              flex: 4,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // FittedBox: on the narrowest wide layouts the controls scale down instead of overflowing.
                    const FittedBox(fit: BoxFit.scaleDown, child: TransportControls()),
                    if (track != null) const SeekBar(inline: true),
                  ],
                ),
              ),
            ),
            Expanded(
              flex: 3,
              // Scales down on the narrowest wide layouts instead of overflowing.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onToggleSidePanel != null)
                      IconButton(
                        tooltip: 'Now playing view',
                        color: sidePanelOpen ? AppColors.accent : null,
                        onPressed: onToggleSidePanel,
                        icon: const Icon(Icons.view_sidebar_outlined, size: 20),
                      ),
                    // In the expanded player, lyrics open beside the cover instead.
                    ListenableBuilder(
                      listenable: Listenable.merge([fullScreenPlayer, expandedPlayerLyrics]),
                      builder: (context, _) {
                        final beside = fullScreenPlayer.value;
                        return IconButton(
                          tooltip: 'Lyrics',
                          color: beside && expandedPlayerLyrics.value ? AppColors.accent : null,
                          onPressed: track == null
                              ? null
                              : beside
                              ? () => expandedPlayerLyrics.value = !expandedPlayerLyrics.value
                              : shell.openLyrics,
                          icon: const Icon(Icons.lyrics_outlined, size: 20),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: 'Queue',
                      onPressed: shell.openQueue,
                      icon: const Icon(Icons.queue_music_rounded, size: 20),
                    ),
                    // The bar spans the whole window, so its own width decides (not the content area's).
                    if (MediaQuery.sizeOf(context).width > 860) const VolumeSlider(),
                    IconButton(
                      tooltip: 'Mini player',
                      onPressed: () => setMiniPlayer(true),
                      icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 20),
                    ),
                    ValueListenableBuilder(
                      valueListenable: fullScreenPlayer,
                      builder: (context, on, _) => IconButton(
                        tooltip: on ? 'Close expanded player' : 'Expanded player',
                        color: on ? AppColors.accent : null,
                        onPressed: track == null && !on ? null : () => showExpandedPlayer(!on),
                        icon: Icon(on ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded, size: 18),
                      ),
                    ),
                    ValueListenableBuilder(
                      valueListenable: windowFullScreen,
                      builder: (context, on, _) => IconButton(
                        tooltip: on ? 'Exit full screen' : 'Full screen',
                        onPressed: track == null && !on ? null : () => setFullScreenPlayer(!on),
                        icon: Icon(on ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, size: 22),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Text that underlines on hover and navigates on click.
class _LinkText extends StatefulWidget {
  const _LinkText(this.text, {required this.style, required this.onTap});

  final String text;
  final TextStyle? style;

  /// Null for plain text (e.g. streamed songs with no album page in the library).
  final VoidCallback? onTap;

  @override
  State<_LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<_LinkText> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final link = widget.onTap != null;
    return MouseRegion(
      cursor: link ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = link),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style?.copyWith(
            decoration: _hover ? TextDecoration.underline : null,
            color: _hover ? AppColors.textPrimary : null,
          ),
        ),
      ),
    );
  }
}

/// Right-hand panel on large screens: big cover, title, and what's next.
class NowPlayingSidePanel extends StatelessWidget {
  const NowPlayingSidePanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final track = c.currentTrack;
    final next = c.upNext.firstOrNull;
    return ColoredBox(
      color: AppColors.panel,
      child: track == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Play something and it will show up here.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                ),
              ),
            )
          : SmoothScroll(
              builder: (context, scroll) => ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.playingFrom ?? 'Now playing',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(tooltip: 'Close', onPressed: onClose, icon: const Icon(Icons.close_rounded, size: 20)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  AspectRatio(
                    aspectRatio: 1,
                    child: _TrackSwitcher(
                      trackId: track.id,
                      slide: false,
                      child: Artwork(key: ValueKey(track.id), track: track, radius: 8),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
                  ),
                  const SizedBox(height: 4),
                  Text(track.artist, style: text.bodyLarge?.copyWith(color: AppColors.textSecondary)),
                  if (track.album != null) ...[
                    const SizedBox(height: 2),
                    Text(track.album!, style: text.bodyMedium?.copyWith(color: AppColors.textMuted)),
                  ],
                  const SizedBox(height: 12),
                  const QualityBadge(),
                  const SizedBox(height: 16),
                  if (next != null)
                    Container(
                      decoration: BoxDecoration(color: AppColors.elevated, borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Next in queue',
                                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              TextButton(
                                onPressed: shell.openQueue,
                                style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
                                child: const Text('Open queue'),
                              ),
                            ],
                          ),
                          TrackRow(track: next, onTap: () => c.playQueueItem(next)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Full-screen player on phones. Swipe down or tap the chevron to close.
class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final text = Theme.of(context).textTheme;
    final track = c.currentTrack;
    final look = Appearance.instance.nowPlaying;
    return AccentBuilder(
      track: track,
      builder: (context, accent) => GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 400) Navigator.of(context).pop();
        },
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (look == NowPlayingBackground.blurredCover && track != null)
                // A small decode is plenty under this much blur.
                ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 48, sigmaY: 48, tileMode: TileMode.clamp),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: Artwork(track: track, size: 160, radius: 0),
                  ),
                ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                decoration: BoxDecoration(
                  color: look == NowPlayingBackground.black ? Colors.black : null,
                  gradient: switch (look) {
                    NowPlayingBackground.color => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [accent, Color.lerp(accent, Colors.black, 0.75)!, Colors.black],
                      stops: const [0, 0.6, 1],
                    ),
                    // Darkens the blurred cover towards the controls, so text stays readable.
                    NowPlayingBackground.blurredCover => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x40000000), Color(0xA6000000), Colors.black],
                      stops: [0, 0.6, 1],
                    ),
                    NowPlayingBackground.black => null,
                  },
                ),
                child: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Leave room for the controls; never let the cover push them off-screen.
                      // On very short windows the cover (then the quality badge) makes way.
                      final showBadge = constraints.maxHeight >= 480;
                      final room = constraints.maxHeight - (showBadge ? 376 : 340);
                      final art = math.min(constraints.maxWidth - 48, room);
                      final narrow = constraints.maxWidth < 320;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  tooltip: 'Close',
                                  color: Colors.white,
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
                                ),
                                Expanded(
                                  child: Column(
                                    children: [
                                      Text(
                                        'PLAYING FROM',
                                        style: text.labelSmall?.copyWith(letterSpacing: 1.2, color: Colors.white70),
                                      ),
                                      Text(
                                        c.playingFrom ?? 'Your library',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                    ],
                                  ),
                                ),
                                if (!narrow)
                                  IconButton(
                                    tooltip: 'Lyrics',
                                    color: Colors.white,
                                    onPressed: ShellScope.of(context).openLyrics,
                                    icon: const Icon(Icons.lyrics_outlined),
                                  ),
                                IconButton(
                                  tooltip: 'Queue',
                                  color: Colors.white,
                                  onPressed: ShellScope.of(context).openQueue,
                                  icon: const Icon(Icons.queue_music_rounded),
                                ),
                              ],
                            ),
                            const Spacer(),
                            if (art >= 96)
                              Hero(
                                tag: 'now-playing-art',
                                child: DecoratedBox(
                                  decoration: const BoxDecoration(
                                    boxShadow: [
                                      BoxShadow(color: Colors.black45, blurRadius: 32, offset: Offset(0, 12)),
                                    ],
                                  ),
                                  child: Artwork(track: track, size: art, radius: 8),
                                ),
                              ),
                            const Spacer(),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        track?.title ?? 'Nothing playing',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: text.headlineSmall?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        track?.artist ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: text.titleMedium?.copyWith(color: Colors.white70),
                                      ),
                                      if (showBadge) ...[const SizedBox(height: 8), const QualityBadge(onDark: true)],
                                    ],
                                  ),
                                ),
                                if (track != null) ...[
                                  DownloadButton(track: track, size: 26, color: Colors.white),
                                  LikeButton(track: track, size: 28, color: Colors.white),
                                  TrackMenuButton(track: track, color: Colors.white),
                                ],
                              ],
                            ),
                            const SizedBox(height: 16),
                            const SeekBar(),
                            const SizedBox(height: 8),
                            const TransportControls(large: true),
                            const SizedBox(height: 24),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cross-fades (and nudges up) whatever shows the current song when it changes.
class _TrackSwitcher extends StatelessWidget {
  const _TrackSwitcher({required this.trackId, required this.child, this.slide = true});

  final String? trackId;
  final Widget child;
  final bool slide;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 260),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
    transitionBuilder: (child, anim) => FadeTransition(
      opacity: anim,
      child: slide
          ? SlideTransition(
              position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(anim),
              child: child,
            )
          : child,
    ),
    child: child,
  );
}

/// The mini player's progress line, updated every frame.
class _MiniProgress extends StatefulWidget {
  const _MiniProgress({required this.builder});

  final AsyncWidgetBuilder<Duration> builder;

  @override
  State<_MiniProgress> createState() => _MiniProgressState();
}

class _MiniProgressState extends State<_MiniProgress> {
  Stream<Duration>? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _position ??= smoothPosition(PlayerScope.read(context).player);
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(stream: _position, builder: widget.builder);
}

/// Desktop expanded player: the cover art (and lyrics beside it, if asked)
/// fills the space above the player bar, inside the window or with the
/// window full screen (Esc, F11 or the bar's buttons leave).
final fullScreenPlayer = ValueNotifier<bool>(false);

/// Whether the window fills the screen too.
final windowFullScreen = ValueNotifier<bool>(false);

/// Lyrics beside the cover in the expanded player.
final expandedPlayerLyrics = ValueNotifier<bool>(false);

/// Expanded player with the window full screen, or neither.
Future<void> setFullScreenPlayer(bool on) => showExpandedPlayer(on, fullScreen: on);

/// Opens or closes the expanded player; [fullScreen] makes the window fill the screen as well.
Future<void> showExpandedPlayer(bool on, {bool fullScreen = false}) async {
  fullScreenPlayer.value = on;
  final full = on && fullScreen;
  if (windowFullScreen.value == full) return;
  windowFullScreen.value = full;
  try {
    await windowManager.setFullScreen(full);
  } catch (e) {
    debugPrint('Full screen: $e'); // the view still works inside the window
  }
}

class FullScreenPlayer extends StatefulWidget {
  const FullScreenPlayer({super.key});

  @override
  State<FullScreenPlayer> createState() => _FullScreenPlayerState();
}

class _FullScreenPlayerState extends State<FullScreenPlayer> {
  bool _hint = true;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    _hintTimer = Timer(const Duration(seconds: 3), () => setState(() => _hint = false));
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  /// The cover with the title and what's next under it, sized to [box].
  Widget _cover(BuildContext context, Track track, Track? next, BoxConstraints box, {required double widthShare}) {
    final text = Theme.of(context).textTheme;

    // Room for the title lines and "Next" under the cover.
    final art = math.min(box.maxHeight - 150, box.maxWidth * widthShare).clamp(120.0, 900.0);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: art,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 16))],
              ),
              child: _TrackSwitcher(
                trackId: track.id,
                slide: false,
                child: Artwork(key: ValueKey(track.id), track: track, radius: 12),
              ),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: math.min(math.max(art, 420), box.maxWidth * widthShare),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        next == null ? track.artist : '${track.artist}   ·   Next: ${next.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge?.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                LikeButton(track: track, size: 26),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final text = Theme.of(context).textTheme;
    final track = c.currentTrack;
    final next = c.upNext.firstOrNull;
    return AccentBuilder(
      track: track,
      builder: (context, accent) => AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        color: Color.lerp(accent, Colors.black, 0.2),
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 20, 20, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.playingFrom ?? track?.album ?? 'Now playing',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      // Queue, volume etc. are in the player bar right below.
                      if (track != null)
                        ValueListenableBuilder(
                          valueListenable: expandedPlayerLyrics,
                          builder: (context, on, _) => LyricsToggleButton(
                            on: on,
                            icon: Icons.lyrics_outlined,
                            tooltip: on ? 'Hide lyrics' : 'Lyrics',
                            onPressed: () => expandedPlayerLyrics.value = !on,
                          ),
                        ),
                      const SizedBox(width: 4),
                      ValueListenableBuilder(
                        valueListenable: windowFullScreen,
                        builder: (context, full, _) => IconButton(
                          tooltip: full ? 'Exit full screen' : 'Close expanded player',
                          onPressed: () => showExpandedPlayer(false),
                          icon: Icon(full ? Icons.fullscreen_exit_rounded : Icons.close_fullscreen_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: track == null
                      ? Center(child: Text('Nothing is playing', style: text.titleMedium))
                      : ValueListenableBuilder(
                          valueListenable: expandedPlayerLyrics,
                          builder: (context, lyrics, _) => LayoutBuilder(
                            builder: (context, box) {
                              if (!lyrics) return _cover(context, track, next, box, widthShare: 0.5);
                              final lyricsView = Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: Padding(
                                        padding: const EdgeInsets.only(right: 20),
                                        child: LyricsExtrasButtons(key: ValueKey(track.id), track: track),
                                      ),
                                    ),
                                    Expanded(child: LyricsView(track: track)),
                                  ],
                                ),
                              );
                              // Too narrow for both: the lyrics alone.
                              if (box.maxWidth < 900) return lyricsView;
                              return Row(
                                children: [
                                  Expanded(
                                    flex: 5,
                                    child: LayoutBuilder(
                                      builder: (context, half) => _cover(context, track, next, half, widthShare: 0.8),
                                    ),
                                  ),
                                  Expanded(flex: 6, child: lyricsView),
                                ],
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
            // Tells first-timers how to get out, then fades away.
            Positioned(
              top: 20,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _hint && windowFullScreen.value ? 1 : 0,
                    duration: const Duration(milliseconds: 400),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: const Color(0xE6202020), borderRadius: BorderRadius.circular(8)),
                      child: Text('Press Esc to exit full screen', style: text.bodyMedium),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Desktop mini player: the window shrinks to the cover with controls and
/// stays on top of other windows, like Spotify's. The full player comes back
/// at its old size and place.
final miniPlayer = ValueNotifier<bool>(false);
Rect? _boundsBeforeMini;

Future<void> setMiniPlayer(bool on) async {
  if (miniPlayer.value == on) return;
  if (on) await setFullScreenPlayer(false);
  try {
    if (on) {
      _boundsBeforeMini = await windowManager.getBounds();
      await windowManager.setMinimumSize(const Size(220, 220));
      miniPlayer.value = true;
      await windowManager.setSize(const Size(340, 340));
      await windowManager.setAlwaysOnTop(true);
    } else {
      miniPlayer.value = false;
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(320, 420));
      if (_boundsBeforeMini case final b?) await windowManager.setBounds(b);
    }
  } catch (e) {
    // Tiling compositors may refuse to resize; the view switches anyway.
    debugPrint('Mini player window: $e');
    miniPlayer.value = on;
  }
}

class MiniPlayerWindow extends StatefulWidget {
  const MiniPlayerWindow({super.key});

  @override
  State<MiniPlayerWindow> createState() => _MiniPlayerWindowState();
}

class _MiniPlayerWindowState extends State<MiniPlayerWindow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final text = Theme.of(context).textTheme;
    final track = c.currentTrack;
    // No Tooltips in here: this sits outside the app's Navigator (no Overlay).
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: ColoredBox(
        color: AppColors.background,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Dragging anywhere on the cover moves the window.
            DragToMoveArea(
              child: track == null
                  ? const SizedBox.expand()
                  : _TrackSwitcher(
                      trackId: track.id,
                      slide: false,
                      child: Artwork(key: ValueKey(track.id), track: track, radius: 0),
                    ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                  onPressed: () => setMiniPlayer(false),
                  icon: const Icon(Icons.open_in_full_rounded, size: 18),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: const Color(0xCC000000),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track?.title ?? 'Nothing playing',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (track != null)
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                      ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 160),
                      child: !_hover
                          ? const SizedBox(width: double.infinity, height: 6)
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(onPressed: c.previous, icon: const Icon(Icons.skip_previous_rounded)),
                                PlayButton(size: 36, playing: c.isPlaying, onPressed: c.canPlay ? c.togglePlay : null),
                                IconButton(onPressed: c.next, icon: const Icon(Icons.skip_next_rounded)),
                              ],
                            ),
                    ),
                    _MiniProgress(
                      builder: (context, snap) {
                        final total = c.player.duration?.inMilliseconds ?? 0;
                        final pos = snap.data?.inMilliseconds ?? 0;
                        return LinearProgressIndicator(
                          value: total == 0 ? 0 : (pos / total).clamp(0, 1),
                          minHeight: 2,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
