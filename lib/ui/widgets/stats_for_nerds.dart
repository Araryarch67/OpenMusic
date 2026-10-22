import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/track.dart';
import '../../services/audio_engine.dart';
import '../../services/player_controller.dart';
import '../../services/youtube_audio_source.dart';
import '../theme.dart';
import 'menus.dart';
import 'signal_path.dart';

/// Stats for nerds, as on YouTube: the song playing, read live, over the
/// now-playing cover. One switch for every cover, so it stays on across views.
final statsForNerds = ValueNotifier<bool>(false);

/// The now-playing cover: Stats for nerds over it while they're on, and a
/// menu on right-click / long-press to turn them on (as YouTube's video has).
class NowPlayingCover extends StatelessWidget {
  const NowPlayingCover({super.key, required this.child});

  final Widget child;

  static Future<void> _menu(BuildContext context, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
      color: AppColors.menu,
      shape: menuShape,
      items: [
        PopupMenuItem(
          value: 'stats',
          child: MenuRow(
            leading: const Icon(Icons.query_stats_rounded),
            title: Text(statsForNerds.value ? 'Hide stats for nerds' : 'Stats for nerds'),
          ),
        ),
        const PopupMenuItem(
          value: 'path',
          child: MenuRow(leading: Icon(Icons.graphic_eq_rounded), title: Text('Signal path')),
        ),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'stats':
        statsForNerds.value = !statsForNerds.value;
      case 'path':
        await showSignalPath(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AudioEngine.supported) return child;
    return GestureDetector(
      onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
      onLongPressStart: (d) => _menu(context, d.globalPosition),
      child: ValueListenableBuilder(
        valueListenable: statsForNerds,
        builder: (context, on, cover) => Stack(
          // The cover keeps the size it was given (a square box, a fixed size).
          fit: StackFit.passthrough,
          children: [
            cover!,
            if (on)
              const Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Align(alignment: Alignment.topLeft, child: _StatsPanel()),
                ),
              ),
          ],
        ),
        child: child,
      ),
    );
  }
}

class _StatsPanel extends StatefulWidget {
  const _StatsPanel();

  @override
  State<_StatsPanel> createState() => _StatsPanelState();
}

class _StatsPanelState extends State<_StatsPanel> {
  SignalPath? _path;
  ({double? buffered, String? gain}) _extra = (buffered: null, gain: null);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    final audio = PlayerScope.read(context).audio;
    final path = await audio.signalPath();
    final extra = await audio.nerdStats();
    if (mounted) {
      setState(() {
        _path = path;
        _extra = extra;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// YouTube's labels, where a music player has the same thing.
  List<(String, String)> _rows(PlayerController c, Track track) {
    final p = _path;
    if (p == null) return [('Status', c.casting ? 'Playing on another device' : 'Waiting for audio')];
    final streaming = c.player.sequenceState.currentSource is YoutubeAudioSource;
    final yt = track.videoId == null ? null : YoutubeAudioSource.statsOf(track.videoId!);
    final stream = streaming ? yt?.stream : null;
    final volume = c.volume;
    String db(double gain) => '${(20 * math.log(gain) / math.ln10).toStringAsFixed(1)} dB';
    final level = c.audio.effectiveLeveling;
    final leveling = level == VolumeLeveling.off
        ? 'off'
        : '${level.label.toLowerCase()}${_extra.gain == null ? ', no tag' : ' ${_extra.gain}'}';
    return [
      if (track.videoId case final id?)
        streaming ? ('Video ID / itag', '$id / ${stream?.formatId ?? '-'}') : ('Video ID', '$id (downloaded copy)')
      else
        ('File', (track.path ?? track.uri.toString()).split(RegExp(r'[/\\]')).last),
      (
        'Codecs',
        stream == null ? '${p.codec} in ${p.container.split(',').first}' : '${stream.codec} (${stream.formatId})',
      ),
      (
        'Bitrate',
        switch ((((p.bitrate ?? 0) / 1000).round(), stream?.kbps ?? 0)) {
          (0, 0) => '-',
          (final now, 0) => '$now kbps',
          (0, final avg) => '$avg kbps (avg)',
          (final now, final avg) => '$now kbps (avg $avg)',
        },
      ),
      (
        'Decoded',
        '${SignalPath.describe(p.inFormat, p.inRate, stored: p.sourceBits)} · ${p.inChannels} ch (${p.inFormat})',
      ),
      ('Output', '${SignalPath.describe(p.outFormat, p.outRate)} · ${p.outChannels} ch · ${outputName(p)}'),
      (
        'Volume / Leveling',
        '${p.isDop ? '100% (DoP)' : '${(volume * 100).round()}% (${p.volume <= 0 ? 'muted' : db(p.volume / 100)})'} / $leveling',
      ),
      if (stream?.loudness case final lufs?)
        (
          'Loudness',
          switch (stream!.loudnessTarget) {
            null => '${lufs.toStringAsFixed(1)} LUFS',
            // The level YouTube's own player brings it to.
            final target => '${lufs.toStringAsFixed(1)} LUFS (target ${target.toStringAsFixed(0)} LUFS)',
          },
        ),
      if (streaming && yt?.bitsPerSecond != null) ('Connection Speed', '${(yt!.bitsPerSecond! / 1000).round()} Kbps'),
      if (streaming && yt != null)
        ('Network Activity', '${_bytes(yt.received)}${stream?.size == null ? '' : ' of ${_bytes(stream!.size!)}'}'),
      if (_extra.buffered case final s?) ('Buffer Health', '${s.toStringAsFixed(2)} s'),
      if (stream != null) ('Stream URL from', stream.via),
    ];
  }

  static String _bytes(int n) => n < 1 << 20 ? '${(n / 1024).round()} KB' : '${(n / (1 << 20)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final track = c.currentTrack;
    if (track == null) return const SizedBox.shrink();
    final rows = _rows(c, track);
    final base = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Colors.white,
      fontSize: 11.5,
      height: 1.3,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget icon(IconData i, String tip, VoidCallback onTap) => IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(i, size: 15, color: Colors.white70),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      padding: EdgeInsets.zero,
    );
    final panel = DecoratedBox(
      decoration: BoxDecoration(color: const Color(0xCC1C1C1C), borderRadius: BorderRadius.circular(6)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 2, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Stats for nerds', style: base?.copyWith(color: Colors.white70)),
                ),
                icon(Icons.copy_rounded, 'Copy stats', () {
                  Clipboard.setData(ClipboardData(text: [for (final (k, v) in rows) '$k: $v'].join('\n')));
                  ScaffoldMessenger.maybeOf(context)
                      ?.showSnackBar(const SnackBar(content: Text('Stats copied'), duration: Duration(seconds: 2)));
                }),
                icon(Icons.close_rounded, 'Hide stats', () => statsForNerds.value = false),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Table(
                columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
                defaultVerticalAlignment: TableCellVerticalAlignment.top,
                children: [
                  for (final (label, value) in rows)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Text(label, style: base?.copyWith(fontWeight: FontWeight.w700)),
                        ),
                        Text(value, style: base),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    // Never wider than it needs, never past the cover: small covers scale it down.
    return LayoutBuilder(
      builder: (context, box) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topLeft,
        child: SizedBox(width: math.min(box.maxWidth, 440), child: panel),
      ),
    );
  }
}
