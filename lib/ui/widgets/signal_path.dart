import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/audio_engine.dart';
import '../../services/player_controller.dart';
import '../theme.dart';

/// Polls mpv for the live signal path while it's on screen.
class _SignalPathBuilder extends StatefulWidget {
  const _SignalPathBuilder({required this.builder});

  final Widget Function(BuildContext context, SignalPath? path) builder;

  @override
  State<_SignalPathBuilder> createState() => _SignalPathBuilderState();
}

class _SignalPathBuilderState extends State<_SignalPathBuilder> {
  SignalPath? _path;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    final path = await PlayerScope.read(context).audio.signalPath();
    if (mounted) setState(() => _path = path);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _path);
}

String _codecName(SignalPath p) => p.isDop
    ? 'DSD${p.dopBitRate! ~/ 44100}'
    : switch (p.codec) {
        'flac' => 'FLAC',
        'alac' => 'ALAC',
        'opus' => 'Opus',
        'vorbis' => 'Vorbis',
        'aac' => 'AAC',
        'mp3' || 'mp3float' => 'MP3',
        'wavpack' => 'WavPack',
        'ape' => "Monkey's Audio",
        final c when c.startsWith('pcm_') => p.container == 'aiff' ? 'AIFF' : 'WAV',
        final c when c.startsWith('dsd_') => 'DSD${p.inRate * 8 ~/ 44100}',
        'dst' => 'DST (SACD)',
        final c => c.toUpperCase(),
      };

/// Small "FLAC · 24-bit / 96 kHz" label; tap for the full signal path.
class QualityBadge extends StatelessWidget {
  const QualityBadge({super.key, this.onDark = false});

  /// On a coloured background (phone now playing): white text instead of grey.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    if (!AudioEngine.supported) return const SizedBox.shrink();
    return _SignalPathBuilder(
      builder: (context, p) {
        if (p == null) return const SizedBox(height: 28);
        final label = p.isDop
            ? '${_codecName(p)} · DoP'
            : p.lossless && !p.isDsd
            ? '${_codecName(p)} · ${SignalPath.describe(p.inFormat, p.inRate, stored: p.sourceBits)}'
            : p.isDsd
            ? '${_codecName(p)} → PCM ${SignalPath.formatRate(p.inRate)}'
            : '${_codecName(p)}${p.bitrate == null || p.bitrate == 0 ? '' : ' · ${(p.bitrate! / 1000).round()} kbps'}';
        final color = p.bitPerfect
            ? AppColors.accent
            : onDark
            ? Colors.white70
            : AppColors.textSecondary;
        return Align(
          alignment: Alignment.centerLeft,
          child: Tooltip(
            message: 'Signal path',
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => showSignalPath(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: color.withValues(alpha: 0.6)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (p.bitPerfect) ...[
                      Icon(Icons.verified_rounded, size: 14, color: color),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      p.bitPerfect ? 'Bit-perfect · $label' : label,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: color, fontWeight: FontWeight.w700, letterSpacing: 0.3),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showSignalPath(BuildContext context) {
  final c = PlayerScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.elevated,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => PlayerScope(controller: c, child: const _SignalPathSheet()),
  );
}

class _SignalPathSheet extends StatelessWidget {
  const _SignalPathSheet();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _SignalPathBuilder(
      builder: (context, p) {
        if (p == null) {
          return const Padding(padding: EdgeInsets.all(32), child: Text('Nothing is playing.'));
        }
        final (verdict, verdictColor, detail) = p.isDop && p.bitPerfect
            ? (
                'Native DSD',
                AppColors.accent,
                'The DSD stream reaches your DAC as it is, packed as DoP. A DAC that supports DoP '
                    'shows DSD; one that doesn\'t plays a faint hiss (then turn off Native DSD).',
              )
            : p.isDop
            ? (
                'DoP is being changed',
                Theme.of(context).colorScheme.error,
                'Something between OpenMusic and your DAC changes the samples, so the DAC can\'t see the DSD. '
                    'Choose a direct output in Settings › Advanced audio.',
              )
            : p.bitPerfect
            ? ('Bit-perfect', AppColors.accent, 'Every sample reaches your DAC exactly as it is stored in the file.')
            : p.untouched && p.mixerResamples
            ? (
                'Resampled by the system mixer',
                AppColors.textPrimary,
                'OpenMusic leaves the sound alone, but the system mixer runs your DAC at '
                    '${SignalPath.formatRate(p.dac!.rate)} instead of ${SignalPath.formatRate(p.inRate)}. '
                    'Turn on Bit-perfect mode in Settings › Advanced audio to send it as it is.',
              )
            : p.untouched && p.viaSystemMixer
            ? (
                'Lossless to the system mixer',
                AppColors.textPrimary,
                'Nothing in OpenMusic changes the sound, but the system mixer may resample it. '
                    '${AudioEngine.hasExclusiveMode ? 'For bit-perfect, turn on Bit-perfect mode and Exclusive mode in Settings › Advanced audio (other apps go silent meanwhile).' : 'For bit-perfect, turn on Bit-perfect mode in Settings › Advanced audio.'}',
              )
            : p.isDsd
            ? (
                'DSD converted to PCM',
                AppColors.textPrimary,
                'DSD is decoded to high-rate PCM. To send it to your DAC as DSD, turn on Bit-perfect mode'
                    '${AudioEngine.hasExclusiveMode ? ', Exclusive mode' : ''} and Native DSD (DoP) in Settings › Advanced audio.',
              )
            : (
                'Processed',
                AppColors.textSecondary,
                'Something below changes the samples. That is fine if it is what you want.',
              );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Signal path', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      p.bitPerfect ? Icons.verified_rounded : Icons.graphic_eq_rounded,
                      color: verdictColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      verdict,
                      style: text.titleMedium?.copyWith(color: verdictColor, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(detail, style: text.bodySmall?.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 20),
                _Stage(
                  title: 'Source',
                  value:
                      '${_codecName(p)}${p.lossless ? ' (lossless)' : ''}'
                      '${p.sourceBits == null ? '' : ' · ${p.sourceBits}-bit'}'
                      '${p.bitrate == null || p.bitrate == 0 ? '' : ' · ${(p.bitrate! / 1000).round()} kbps'}',
                ),
                _Stage(
                  title: 'Decoded',
                  value:
                      '${SignalPath.describe(p.inFormat, p.inRate)} · ${_channels(p.inChannels)}'
                      '${p.sourceBits != null && p.sourceBits != SignalPath.bitsOf(p.inFormat) && !p.inFormat.startsWith('float') ? ' (${p.sourceBits}-bit, padded losslessly)' : ''}',
                ),
                for (final f in p.filters) _Stage(title: 'DSP', value: f, changes: true),
                if (p.leveling) const _Stage(title: 'Volume leveling', value: 'ReplayGain', changes: true),
                _Stage(
                  title: 'Volume',
                  value: (p.volume - 100).abs() < 0.01
                      ? '100% (untouched)'
                      : p.volume <= 0
                      ? 'Muted'
                      : '${(20 * math.log(p.volume / 100) / math.ln10).toStringAsFixed(1)} dB (64-bit float)',
                  changes: (p.volume - 100).abs() >= 0.01,
                ),
                if (p.inRate != p.outRate)
                  _Stage(
                    title: 'Resampled',
                    value:
                        '${SignalPath.formatRate(p.inRate)} → ${SignalPath.formatRate(p.outRate)} · ${AudioEngine.resamplerName}',
                    changes: true,
                  ),
                _Stage(
                  title: 'Output',
                  value:
                      '${SignalPath.describe(p.outFormat, p.outRate)} · ${_channels(p.outChannels)}\n'
                      '${outputName(p)}',
                  changes: p.viaSystemMixer,
                  last: p.dac == null,
                ),
                if (p.dac case final dac?)
                  _Stage(
                    title: 'DAC receives',
                    value:
                        '${dac.bits == null ? dac.format : '${dac.bits}-bit${dac.isFloat ? ' float' : ''}'} / '
                        '${SignalPath.formatRate(dac.rate)} · ${_channels(dac.channels)} (${dac.format})\n${p.dacName ?? ''}',
                    changes: !p.dacMatches,
                    last: true,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _channels(int n) => switch (n) {
    1 => 'mono',
    2 => 'stereo',
    final n => '$n channels',
  };
}

/// The output API and device, e.g. "WASAPI shared · {0.0.0.00000000}.{…}".
String outputName(SignalPath p) {
  final api = switch (p.output) {
    'pipewire' => 'PipeWire (system mixer)',
    'pulse' => 'PulseAudio (system mixer)',
    'alsa' => p.viaSystemMixer ? 'ALSA' : 'ALSA, direct to hardware',
    'wasapi' => p.exclusive ? 'WASAPI exclusive' : 'WASAPI shared',
    'asio' => 'ASIO',
    'coreaudio' => 'Core Audio',
    final o => o,
  };
  return p.device == 'auto' || p.device.isEmpty ? api : '$api · ${p.device.split('/').last}';
}

class _Stage extends StatelessWidget {
  const _Stage({required this.title, required this.value, this.changes = false, this.last = false});

  final String title;
  final String value;

  /// This stage alters the samples.
  final bool changes;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dot = changes ? AppColors.textSecondary : AppColors.accent;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                const SizedBox(height: 4),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                if (!last) Expanded(child: Container(width: 2, color: AppColors.hover)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.labelMedium?.copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 2),
                  Text(value, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
