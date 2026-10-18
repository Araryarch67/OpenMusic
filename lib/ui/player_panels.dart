import 'package:flutter/material.dart';

import '../services/player_controller.dart';
import 'shell_scope.dart';
import 'theme.dart';
import 'widgets/controls.dart';
import 'widgets/track_row.dart';

/// Floating bar above the bottom tabs on phones, tinted with the cover colour.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final track = c.currentTrack;
    if (track == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return AccentBuilder(
      track: track,
      builder: (context, accent) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: Material(
          color: Color.lerp(accent, Colors.black, 0.35),
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
                  child: Row(
                    children: [
                      Hero(
                        tag: 'now-playing-art',
                        child: Artwork(track: track, size: 40),
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
                      IconButton(
                        tooltip: c.isPlaying ? 'Pause' : 'Play',
                        color: Colors.white,
                        iconSize: 30,
                        onPressed: c.togglePlay,
                        icon: Icon(c.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      ),
                    ],
                  ),
                ),
                StreamBuilder<Duration>(
                  stream: c.player.positionStream,
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
              child: track == null
                  ? const SizedBox.shrink()
                  : Row(
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
                                onTap: () {
                                  final album = c.albumOf(track);
                                  if (album != null) shell.openCollection(album);
                                },
                              ),
                              const SizedBox(height: 2),
                              _LinkText(
                                track.artist,
                                style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                                onTap: () {
                                  final artist = c.artistNamed(track.artist);
                                  if (artist != null) shell.openCollection(artist);
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onToggleSidePanel != null)
                    IconButton(
                      tooltip: 'Now playing view',
                      color: sidePanelOpen ? AppColors.accent : null,
                      onPressed: onToggleSidePanel,
                      icon: const Icon(Icons.view_sidebar_outlined, size: 20),
                    ),
                  IconButton(
                    tooltip: 'Queue',
                    onPressed: shell.openQueue,
                    icon: const Icon(Icons.queue_music_rounded, size: 20),
                  ),
                  if (shell.width > 860) const VolumeSlider(),
                ],
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
  final VoidCallback onTap;

  @override
  State<_LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<_LinkText> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
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
          : ListView(
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
                AspectRatio(aspectRatio: 1, child: Artwork(track: track, radius: 8)),
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
                const SizedBox(height: 24),
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
    return AccentBuilder(
      track: track,
      builder: (context, accent) => GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 400) Navigator.of(context).pop();
        },
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [accent, Color.lerp(accent, Colors.black, 0.75)!, Colors.black],
                stops: const [0, 0.6, 1],
              ),
            ),
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Leave room for the controls; never let the cover push them off-screen.
                  final art = (constraints.maxWidth - 48).clamp(160.0, constraints.maxHeight - 340);
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
                            IconButton(
                              tooltip: 'Queue',
                              color: Colors.white,
                              onPressed: ShellScope.of(context).openQueue,
                              icon: const Icon(Icons.queue_music_rounded),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Hero(
                          tag: 'now-playing-art',
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 32, offset: Offset(0, 12))],
                            ),
                            child: Artwork(track: track, size: art, radius: 8),
                          ),
                        ),
                        const Spacer(),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track?.title ?? 'Nothing playing',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                track?.artist ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.titleMedium?.copyWith(color: Colors.white70),
                              ),
                            ],
                          ),
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
        ),
      ),
    );
  }
}
