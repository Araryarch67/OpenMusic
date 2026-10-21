import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../../services/lyrics.dart';
import '../../services/lyrics_translation.dart';
import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/smooth_scroll.dart';
import '../navigation.dart';

/// Lyrics of whatever is playing, following the song line by line.
///
/// Lives in the content area on desktop and full screen on phones. The
/// background is the cover's own colour, like the now-playing view.
class LyricsPage extends StatelessWidget {
  const LyricsPage({super.key, this.fullScreen = false});

  /// Phone: pushed over everything, with its own close button and mini controls.
  final bool fullScreen;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final track = c.currentTrack;
    final text = Theme.of(context).textTheme;
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    return AccentBuilder(
      track: track,
      builder: (context, accent) => Material(
        color: track == null ? AppColors.panel : Color.lerp(accent, Colors.black, 0.25),
        child: SafeArea(
          bottom: fullScreen,
          top: fullScreen || ShellScope.of(context).compact,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    if (ShellScope.of(context).history case final history? when !fullScreen)
                      HistoryButtons(history: history)
                    else if (canPop)
                      IconButton(
                        tooltip: fullScreen ? 'Close' : 'Back',
                        color: Colors.white,
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(fullScreen ? Icons.keyboard_arrow_down_rounded : Icons.arrow_back_rounded),
                      )
                    else
                      const SizedBox(width: 8),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Lyrics', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                          if (track != null)
                            Text(
                              '${track.title} · ${track.artist}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(color: Colors.white70),
                            ),
                        ],
                      ),
                    ),
                    if (track != null) _ExtrasButtons(key: ValueKey(track.id), track: track),
                  ],
                ),
              ),
              Expanded(
                // Lines fade out under the header instead of being cut off.
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
                    stops: [0, 0.08, 0.92, 1],
                  ).createShader(rect),
                  child: track == null
                      ? const _Message('Play a song to see its lyrics here.')
                      : _LyricsLoader(key: ValueKey(track.id), track: track),
                ),
              ),
              if (fullScreen && track != null) ...[
                const Padding(padding: EdgeInsets.symmetric(horizontal: 24), child: SeekBar()),
                const TransportControls(large: true),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LyricsLoader extends StatefulWidget {
  const _LyricsLoader({super.key, required this.track});

  final Track track;

  @override
  State<_LyricsLoader> createState() => _LyricsLoaderState();
}

class _LyricsLoaderState extends State<_LyricsLoader> {
  late Future<Lyrics> _lyrics = LyricsService.forTrack(widget.track);

  @override
  Widget build(BuildContext context) => FutureBuilder<Lyrics>(
    future: _lyrics,
    builder: (context, snap) {
      if (snap.hasError) {
        return _Message(
          'Couldn\'t load lyrics. Check your internet connection.',
          action: TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () => setState(() => _lyrics = LyricsService.forTrack(widget.track)),
            child: const Text('Try again'),
          ),
        );
      }
      final lyrics = snap.data;
      if (lyrics == null) return const Center(child: CircularProgressIndicator(color: Colors.white));
      if (lyrics.instrumental) return const _Message('This song is instrumental. Enjoy the music.');
      if (lyrics.isEmpty) return const _Message('No lyrics found for this song.');
      return FadeIn(
        child: lyrics.synced ? _SyncedLyrics(lyrics: lyrics) : _PlainLyrics(lyrics: lyrics),
      );
    },
  );
}

/// "Pronunciation" and "Translation" toggles, shown once the song has lyrics.
class _ExtrasButtons extends StatefulWidget {
  const _ExtrasButtons({super.key, required this.track});

  final Track track;

  @override
  State<_ExtrasButtons> createState() => _ExtrasButtonsState();
}

class _ExtrasButtonsState extends State<_ExtrasButtons> {
  late final Future<Lyrics> _lyrics = LyricsService.forTrack(widget.track);

  @override
  Widget build(BuildContext context) => FutureBuilder<Lyrics>(
    future: _lyrics,
    builder: (context, snap) {
      final l = snap.data;
      if (l == null || l.isEmpty || l.instrumental) return const SizedBox.shrink();
      Widget toggle(ValueNotifier<bool> option, IconData icon, String tooltip) => ValueListenableBuilder(
        valueListenable: option,
        builder: (context, on, _) => IconButton(
          tooltip: tooltip,
          isSelected: on,
          color: Colors.white70,
          selectedIcon: Icon(icon, color: Colors.black),
          style: IconButton.styleFrom(backgroundColor: on ? Colors.white : null),
          onPressed: () => option.value = !on,
          icon: Icon(icon),
        ),
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (LyricsTranslation.hasNonLatin(_lyricLines(l).join('\n')))
            toggle(LyricsTranslation.romanize, Icons.abc_rounded, 'Pronunciation'),
          const SizedBox(width: 4),
          toggle(LyricsTranslation.translate, Icons.translate_rounded, 'Translation'),
        ],
      );
    },
  );
}

List<String> _lyricLines(Lyrics l) => l.synced ? [for (final line in l.lines) line.text] : l.plain!.split('\n');

/// Fetches pronunciation / translation for [lyrics] once either is switched on.
mixin _Extras<T extends StatefulWidget> on State<T> {
  Lyrics get lyrics;
  List<LineExtras>? extras;
  bool _asked = false;

  bool get showRomanized => LyricsTranslation.romanize.value;
  bool get showTranslation => LyricsTranslation.translate.value;

  @override
  void initState() {
    super.initState();
    LyricsTranslation.romanize.addListener(_changed);
    LyricsTranslation.translate.addListener(_changed);
    _fetch();
  }

  @override
  void dispose() {
    LyricsTranslation.romanize.removeListener(_changed);
    LyricsTranslation.translate.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    setState(() {});
    _fetch();
  }

  void _fetch() {
    if (_asked || !(showRomanized || showTranslation)) return;
    _asked = true;
    LyricsTranslation.of(_lyricLines(lyrics)).then(
      (e) {
        if (mounted) setState(() => extras = e);
      },
      onError: (Object _) {
        _asked = false; // switching it off and on again retries
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Couldn\'t translate these lyrics. Check your internet connection.')),
        );
      },
    );
  }

  /// The lines to show under line [i], or null.
  String? extraFor(int i) {
    final e = extras;
    if (e == null || i >= e.length) return null;
    final parts = [if (showRomanized) e[i].romanized, if (showTranslation) e[i].translation].nonNulls;
    return parts.isEmpty ? null : parts.join('\n');
  }
}

TextStyle? _extraStyle(BuildContext context) =>
    Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.3);

class _Message extends StatelessWidget {
  const _Message(this.message, {this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white70),
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    ),
  );
}

TextStyle? _lineStyle(BuildContext context) {
  final compact = ShellScope.of(context).compact;
  return (compact ? Theme.of(context).textTheme.headlineSmall : Theme.of(context).textTheme.headlineMedium)?.copyWith(
    fontWeight: FontWeight.w800,
    height: 1.25,
    letterSpacing: -0.3,
  );
}

class _Source extends StatelessWidget {
  const _Source(this.lyrics);

  final Lyrics lyrics;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32, bottom: 48),
    child: Text(
      'Lyrics from ${lyrics.source}',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white54),
    ),
  );
}

class _PlainLyrics extends StatefulWidget {
  const _PlainLyrics({required this.lyrics});

  final Lyrics lyrics;

  @override
  State<_PlainLyrics> createState() => _PlainLyricsState();
}

class _PlainLyricsState extends State<_PlainLyrics> with _Extras {
  @override
  Lyrics get lyrics => widget.lyrics;

  @override
  Widget build(BuildContext context) {
    final style = _lineStyle(context)?.copyWith(color: Colors.white);
    final lines = lyrics.plain!.split('\n');
    return SmoothScroll(
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.symmetric(horizontal: ShellScope.of(context).compact ? 24 : 40, vertical: 24),
        children: [
          if (extras == null)
            Text(lyrics.plain!, style: style)
          else
            for (var i = 0; i < lines.length; i++) ...[
              Text(lines[i], style: style),
              if (extraFor(i) case final extra?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(extra, style: _extraStyle(context)?.copyWith(color: Colors.white70)),
                ),
            ],
          _Source(lyrics),
        ],
      ),
    );
  }
}

class _SyncedLyrics extends StatefulWidget {
  const _SyncedLyrics({required this.lyrics});

  final Lyrics lyrics;

  @override
  State<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends State<_SyncedLyrics> with _Extras {
  @override
  Lyrics get lyrics => widget.lyrics;

  late final List<GlobalKey> _keys = [for (final _ in widget.lyrics.lines) GlobalKey()];
  final _scroll = SmoothScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _current = -2;

  /// Paused while the user scrolls by hand, so the view doesn't yank back mid-scroll.
  DateTime _userScrolledAt = DateTime(0);

  void _follow(int index) {
    if (index == _current) return;
    _current = index;
    if (DateTime.now().difference(_userScrolledAt) < const Duration(seconds: 4)) return;
    final ctx = index < 0 ? null : _keys[index].currentContext;
    if (ctx == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    final lines = widget.lyrics.lines;
    final style = _lineStyle(context);
    final pad = ShellScope.of(context).compact ? 24.0 : 40.0;
    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        _userScrolledAt = DateTime.now();
        return false;
      },
      child: StreamBuilder<Duration>(
        stream: c.player.positionStream,
        builder: (context, snap) {
          // A little early: a line should light up as it starts, not after.
          final at = widget.lyrics.lineAt((snap.data ?? c.player.position) + const Duration(milliseconds: 150));
          _follow(at);
          return SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(pad, 24, pad, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines.length; i++)
                  _Line(
                    key: _keys[i],
                    text: lines[i].text.isEmpty ? '♪' : lines[i].text,
                    extra: extraFor(i),
                    style: style,
                    color: i == at
                        ? Colors.white
                        : i < at
                        ? Colors.white.withValues(alpha: 0.75)
                        : Colors.black.withValues(alpha: 0.55),
                    onTap: () {
                      _userScrolledAt = DateTime(0);
                      c.player.seek(lines[i].time);
                      if (!c.player.playing) c.player.play();
                    },
                  ),
                _Source(widget.lyrics),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Line extends StatefulWidget {
  const _Line({
    super.key,
    required this.text,
    this.extra,
    required this.style,
    required this.color,
    required this.onTap,
  });

  final String text;

  /// Pronunciation / translation, smaller, under the line.
  final String? extra;
  final TextStyle? style;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_Line> createState() => _LineState();
}

class _LineState extends State<_Line> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: (widget.style ?? const TextStyle()).copyWith(color: _hover ? Colors.white : widget.color),
              child: Text(widget.text),
            ),
            if (widget.extra case final extra?)
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: (_extraStyle(context) ?? const TextStyle()).copyWith(
                  color: (_hover ? Colors.white : widget.color).withValues(alpha: 0.8),
                ),
                child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(extra)),
              ),
          ],
        ),
      ),
    ),
  );
}
