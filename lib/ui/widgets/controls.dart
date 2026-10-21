import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../models/track.dart';
import '../../services/appearance.dart';
import '../../services/metadata.dart';
import '../../services/player_controller.dart';
import '../theme.dart';

String formatDuration(Duration? d) {
  if (d == null) return '--:--';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

String formatTotal(Iterable<Track> tracks) {
  final total = tracks.fold(Duration.zero, (sum, t) => sum + (t.duration ?? Duration.zero));
  if (total == Duration.zero) return '';
  final h = total.inHours, m = total.inMinutes.remainder(60);
  return h > 0 ? '$h hr $m min' : '$m min ${total.inSeconds.remainder(60)} sec';
}

/// Cover art from the file's tags, with a tinted placeholder while loading / if missing.
class Artwork extends StatelessWidget {
  const Artwork({super.key, required this.track, this.size, this.radius = 4, this.circle = false, this.icon});

  final Track? track;

  /// Null means "fill the parent" (use inside AspectRatio / SizedBox).
  final double? size;
  final double radius;
  final bool circle;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = track;
    Widget child;
    if (t == null) {
      child = _placeholder(null);
    } else if (Metadata.hasCachedArtwork(t)) {
      child = _image(context, Metadata.cachedArtwork(t), t);
    } else {
      child = FutureBuilder<Uint8List?>(
        future: Metadata.artwork(t),
        builder: (context, snap) =>
            AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: _image(context, snap.data, t)),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      // ClipRRect / ClipOval have fast paths; a generic ClipPath per cover made scrolling heavy.
      child: circle
          ? ClipOval(child: child)
          : radius == 0
          ? child
          : ClipRRect(borderRadius: BorderRadius.circular(radius), child: child),
    );
  }

  Widget _image(BuildContext context, Uint8List? bytes, Track t) {
    if (bytes == null) return _placeholder(t);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Image(
      key: ValueKey(t.albumKey ?? t.id),
      image: ResizeImage(MemoryImage(bytes), width: ((size ?? 300) * dpr).round(), allowUpscaling: false),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => _placeholder(t),
    );
  }

  Widget _placeholder(Track? t) {
    return LayoutBuilder(
      builder: (context, c) => ColoredBox(
        color: AppColors.hover,
        child: Center(
          child: Icon(
            icon ?? (circle ? Icons.person_outline_rounded : Icons.music_note_outlined),
            size: c.biggest.shortestSide.isFinite ? c.biggest.shortestSide * 0.38 : 24,
            color: AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Rebuilds with the cover-art colour of [track] (falls back to a hashed hue).
class AccentBuilder extends StatelessWidget {
  const AccentBuilder({super.key, required this.track, required this.builder});

  final Track? track;
  final Widget Function(BuildContext context, Color accent) builder;

  /// Stands in for the cover's colour when cover colours are off.
  static const neutral = Color(0xFF3A3A3A);

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (t == null) return builder(context, AppColors.elevated);
    if (!Appearance.instance.coverColors) return builder(context, neutral);
    final cached = Metadata.cachedAccent(t);
    if (cached != null) return builder(context, cached);
    return FutureBuilder<Color>(
      future: Metadata.accent(t),
      builder: (context, snap) => builder(context, snap.data ?? Metadata.fallbackAccent),
    );
  }
}

/// Animated "now playing" bars.
class EqualizerIcon extends StatefulWidget {
  const EqualizerIcon({super.key, required this.playing, this.size = 16, this.color});

  final bool playing;
  final double size;

  /// The accent colour when null.
  final Color? color;

  @override
  State<EqualizerIcon> createState() => _EqualizerIconState();
}

class _EqualizerIconState extends State<EqualizerIcon> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _anim.repeat();
  }

  @override
  void didUpdateWidget(EqualizerIcon old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_anim.isAnimating) _anim.repeat();
    if (!widget.playing) _anim.stop();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const phases = [0.0, 0.35, 0.7, 0.15];
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final p in phases)
              Container(
                width: widget.size / 6,
                height: widget.size * (widget.playing ? 0.25 + 0.75 * (((_anim.value + p) % 1) - 0.5).abs() * 2 : 0.3),
                decoration: BoxDecoration(
                  color: widget.color ?? AppColors.accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Seek slider with elapsed / total labels; drags locally and seeks on release.
/// Playback position at display rate (just_audio interpolates between engine updates).
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, this.inline = false});

  /// Labels either side of the bar (desktop) instead of underneath (mobile).
  final bool inline;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragValue;
  bool _hovering = false;
  Stream<Duration>? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Every frame instead of every ~200 ms: the bar glides rather than ticks.
    _position ??= PlayerScope.read(context).smoothPosition();
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerScope.read(context);
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: AppColors.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]);
    return StreamBuilder<Duration>(
      stream: _position,
      builder: (context, snapshot) {
        final duration = player.duration ?? Duration.zero;
        final position = snapshot.data ?? Duration.zero;
        final max = duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
        final value = (_dragValue ?? position.inMilliseconds.toDouble()).clamp(0.0, max);
        final active = _hovering || _dragValue != null;
        final slider = MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: active && widget.inline ? AppColors.accent : AppColors.textPrimary,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: active || !widget.inline ? 6 : 0, elevation: 0),
              padding: EdgeInsets.zero,
            ),
            child: SizedBox(
              height: 24,
              child: Slider(
                value: value,
                max: max,
                onChanged: duration == Duration.zero ? null : (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) {
                  player.seek(Duration(milliseconds: v.round()));
                  setState(() => _dragValue = null);
                },
              ),
            ),
          ),
        );
        final elapsed = Text(formatDuration(Duration(milliseconds: value.round())), style: style);
        final total = Text(formatDuration(player.duration), style: style);
        if (widget.inline) {
          return Row(
            children: [
              SizedBox(
                width: 44,
                child: Align(alignment: Alignment.centerRight, child: elapsed),
              ),
              const SizedBox(width: 8),
              Expanded(child: slider),
              const SizedBox(width: 8),
              SizedBox(width: 44, child: total),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            slider,
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [elapsed, total]),
          ],
        );
      },
    );
  }
}

/// The big round play/pause button (white on the player, accent on headers).
class PlayButton extends StatelessWidget {
  const PlayButton({
    super.key,
    required this.playing,
    required this.onPressed,
    this.size = 48,
    this.color = AppColors.textPrimary,
    this.iconColor = Colors.black,
    this.loading = false,
  });

  final bool playing;
  final bool loading;
  final VoidCallback? onPressed;
  final double size;
  final Color color;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onPressed: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: onPressed == null ? color.withValues(alpha: 0.4) : color,
          shape: BoxShape.circle,
        ),
        child: loading
            ? Padding(
                padding: EdgeInsets.all(size * 0.3),
                child: CircularProgressIndicator(strokeWidth: 2.5, color: iconColor),
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, anim) => ScaleTransition(
                  scale: Tween(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutBack)),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  key: ValueKey(playing),
                  color: iconColor,
                  size: size * 0.6,
                ),
              ),
      ),
    );
  }
}

/// Grows slightly on hover and shrinks on press, like streaming-app buttons.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onPressed});

  final Widget child;
  final VoidCallback? onPressed;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  double _scale = 1;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => enabled ? setState(() => _scale = 1.06) : null,
      onExit: (_) => setState(() => _scale = 1),
      child: GestureDetector(
        onTapDown: (_) => enabled ? setState(() => _scale = 0.94) : null,
        onTapCancel: () => setState(() => _scale = 1),
        onTapUp: (_) => setState(() => _scale = 1),
        onTap: widget.onPressed,
        child: AnimatedScale(scale: _scale, duration: const Duration(milliseconds: 120), child: widget.child),
      ),
    );
  }
}

/// Shuffle / previous / play-pause / next / repeat.
class TransportControls extends StatelessWidget {
  const TransportControls({super.key, this.large = false});

  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final hasQueue = c.queue.isNotEmpty;
    final skipSize = large ? 40.0 : 26.0;
    final modeSize = large ? 26.0 : 20.0;
    final row = Row(
      mainAxisSize: large ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: large ? MainAxisAlignment.spaceBetween : MainAxisAlignment.center,
      children: [
        ModeButton(
          tooltip: c.shuffle ? 'Disable shuffle' : 'Enable shuffle',
          active: c.shuffle,
          size: modeSize,
          icon: Icons.shuffle_rounded,
          onPressed: hasQueue ? c.toggleShuffle : null,
        ),
        if (!large) const SizedBox(width: 8),
        IconButton(
          tooltip: 'Previous',
          iconSize: skipSize,
          color: AppColors.textPrimary,
          onPressed: hasQueue ? c.previous : null,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        if (!large) const SizedBox(width: 8),
        PlayButton(
          size: large ? 68 : 34,
          playing: c.isPlaying,
          loading: large && c.isBuffering && c.isPlaying,
          onPressed: c.canPlay ? c.togglePlay : null,
        ),
        if (!large) const SizedBox(width: 8),
        IconButton(
          tooltip: 'Next',
          iconSize: skipSize,
          color: AppColors.textPrimary,
          onPressed: c.hasNext ? c.next : null,
          icon: const Icon(Icons.skip_next_rounded),
        ),
        if (!large) const SizedBox(width: 8),
        ModeButton(
          tooltip: switch (c.loopMode) {
            LoopMode.off => 'Enable repeat',
            LoopMode.all => 'Enable repeat one',
            LoopMode.one => 'Disable repeat',
          },
          active: c.loopMode != LoopMode.off,
          size: modeSize,
          icon: c.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
          onPressed: hasQueue ? c.cycleLoopMode : null,
        ),
      ],
    );
    if (!large) return row;
    // The big controls need ~270px; on tinier windows they shrink instead of overflowing.
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 280
          ? row
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(width: 280, child: row),
            ),
    );
  }
}

/// Toggle icon with the little active dot underneath.
/// A toggle (shuffle, repeat): accent-coloured with a dot underneath while on.
class ModeButton extends StatelessWidget {
  const ModeButton({
    super.key,
    required this.tooltip,
    required this.active,
    required this.icon,
    required this.size,
    required this.onPressed,
  });

  final String tooltip;
  final bool active;
  final IconData icon;
  final double size;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        IconButton(
          tooltip: tooltip,
          iconSize: size,
          color: active ? AppColors.accent : AppColors.textSecondary,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
        if (active)
          Positioned(
            bottom: 4,
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
            ),
          ),
      ],
    );
  }
}

class VolumeSlider extends StatelessWidget {
  const VolumeSlider({super.key});

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final player = c.player;
    // While casting, the device's volume (the controller rebuilds this on change).
    return StreamBuilder<double>(
      stream: c.casting ? null : player.volumeStream,
      builder: (context, snapshot) {
        // DoP must reach the DAC untouched: its volume is the one to use.
        final dop = !c.casting && c.audio.dopPlaying != null;
        final volume = dop ? 1.0 : (c.casting ? c.volume : snapshot.data ?? player.volume);
        final setVolume = c.canSetVolume && !dop ? c.setVolume : null;
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: volume == 0 ? 'Unmute' : 'Mute',
              iconSize: 20,
              onPressed: setVolume == null ? null : () => setVolume(volume == 0 ? 1 : 0),
              icon: Icon(
                volume == 0
                    ? Icons.volume_off_rounded
                    : volume < 0.5
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
              ),
            ),
            SizedBox(
              width: 104,
              child: SliderTheme(
                // Horizontal padding keeps the thumb (and its hover halo) off the window edge at 100%.
                data: SliderTheme.of(context).copyWith(padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: Slider(value: volume.clamp(0, 1), onChanged: setVolume),
              ),
            ),
          ],
        );
        return dop ? Tooltip(message: 'DSD goes to your DAC as it is: use the DAC\'s volume', child: row) : row;
      },
    );
  }
}

/// Square (or round, for artists) card used in horizontal shelves and grids.
class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.track,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onPlay,
    this.circle = false,
    this.online = false,
  });

  final Track? track;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final bool circle;

  /// Streams from YouTube Music (needs internet): a small cloud before the subtitle.
  final bool online;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: _hover ? AppColors.hover : AppColors.hover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(8),
            hoverColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: widget.circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
                              borderRadius: widget.circle ? null : BorderRadius.circular(6),
                              boxShadow: const [
                                BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 4)),
                              ],
                            ),
                            child: Artwork(track: widget.track, radius: 6, circle: widget.circle),
                          ),
                        ),
                        if (widget.onPlay != null)
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: AnimatedSlide(
                              duration: const Duration(milliseconds: 180),
                              offset: _hover ? Offset.zero : const Offset(0, 0.25),
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 180),
                                opacity: _hover ? 1 : 0,
                                child: PlayButton(
                                  playing: false,
                                  size: 44,
                                  color: AppColors.accent,
                                  iconColor: AppColors.onAccent,
                                  onPressed: widget.onPlay,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: widget.circle ? TextAlign.center : TextAlign.start,
                    style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: widget.circle ? MainAxisAlignment.center : MainAxisAlignment.start,
                    children: [
                      if (widget.online) ...[const SourceMark(online: true, size: 13), const SizedBox(width: 4)],
                      Flexible(
                        child: Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: widget.circle ? TextAlign.center : TextAlign.start,
                          style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                        ),
                      ),
                    ],
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

/// 2x2 grid of distinct album covers, for collections that span many albums.
class CoverMosaic extends StatelessWidget {
  const CoverMosaic({super.key, required this.tracks, this.size, this.radius = 4});

  final List<Track> tracks;
  final double? size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final seen = <String>{};
    final covers = tracks.where((t) => seen.add(t.albumKey ?? t.id)).take(4).toList();
    if (covers.length < 4) {
      return Artwork(track: covers.firstOrNull, size: size, radius: radius);
    }
    final cell = size == null ? null : size! / 2;
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [for (final t in covers) Artwork(track: t, size: cell, radius: 0)],
        ),
      ),
    );
  }
}

String formatBytes(num bytes) {
  if (bytes < 1024) return '${bytes.round()} B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatEta(Duration d) =>
    d.inMinutes >= 1 ? '${d.inMinutes}m ${d.inSeconds.remainder(60)}s left' : '${d.inSeconds}s left';

/// Where a song plays from: a cloud for YouTube Music (online), a check for
/// songs on this device (offline).
class SourceMark extends StatelessWidget {
  const SourceMark({super.key, required this.online, this.size = 14});

  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: online ? 'YouTube Music: needs internet' : 'On this device: plays offline',
    child: Icon(
      online ? Icons.cloud_outlined : Icons.offline_pin_rounded,
      size: size,
      color: online ? AppColors.textSecondary : AppColors.accent,
    ),
  );
}

/// A panel that turns to frosted glass when that's on in Settings ›
/// Appearance: what scrolls behind shows through, blurred.
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.color, required this.child, this.borderRadius = BorderRadius.zero});

  final Color color;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final look = Appearance.instance;
    if (!look.glass) {
      return Material(color: color, borderRadius: borderRadius, clipBehavior: Clip.antiAlias, child: child);
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: look.blur, sigmaY: look.blur),
        child: Material(
          color: color.withValues(alpha: color.a * 0.55),
          child: child,
        ),
      ),
    );
  }
}
