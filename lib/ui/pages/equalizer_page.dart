import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/audio_engine.dart';
import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/page_scaffold.dart';

/// Ten-band equalizer with presets. Each band's frequency and width can be
/// changed too (tap its label), which makes it a parametric EQ.
class EqualizerPage extends StatelessWidget {
  const EqualizerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final audio = PlayerScope.of(context).audio;
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) => PageScaffold(
        title: 'Equalizer',
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Equalizer', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  Switch(value: audio.eqEnabled, onChanged: audio.bitPerfect ? null : audio.setEqEnabled),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
              child: Text(
                audio.bitPerfect
                    ? 'Bit-perfect mode is on, so the equalizer is bypassed. Turn it off in Settings › Advanced audio.'
                    : 'Pick a preset or drag the sliders. Tap a frequency to fine-tune it.',
                style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final name in eqPresets.keys)
                    ChoiceChip(
                      label: Text(name),
                      selected: audio.eqEnabled && audio.eqPreset == name,
                      onSelected: audio.bitPerfect ? null : (_) => audio.applyPreset(name),
                    ),
                  if (audio.eqPreset == 'Custom')
                    ChoiceChip(label: const Text('Custom'), selected: audio.eqEnabled, onSelected: (_) {}),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: audio.eqEnabled && !audio.bitPerfect ? 1 : 0.4,
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad - 8, 24, pad - 8, 0),
                child: SizedBox(
                  height: 300,
                  child: Row(
                    children: [
                      for (var i = 0; i < audio.bands.length; i++)
                        Expanded(child: _BandSlider(index: i, band: audio.bands[i], audio: audio)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 16, pad, 0),
              child: Row(
                children: [
                  if (audio.preamp < 0)
                    Expanded(
                      child: Text(
                        'Headroom ${audio.preamp.toStringAsFixed(1)} dB, so boosted bands never distort.',
                        style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                      ),
                    )
                  else
                    const Spacer(),
                  TextButton(
                    onPressed: audio.bitPerfect ? null : () => audio.applyPreset('Flat'),
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _freq(double f) => f >= 1000 ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)}k' : f.toStringAsFixed(0);

class _BandSlider extends StatelessWidget {
  const _BandSlider({required this.index, required this.band, required this.audio});

  final int index;
  final EqBand band;
  final AudioEngine audio;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final enabled = audio.eqEnabled && !audio.bitPerfect;
    return Column(
      children: [
        Text(
          '${band.gain > 0 ? '+' : ''}${band.gain.toStringAsFixed(band.gain % 1 == 0 ? 0 : 1)}',
          style: text.labelSmall?.copyWith(color: AppColors.textSecondary),
        ),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              value: band.gain.clamp(-12, 12),
              min: -12,
              max: 12,
              divisions: 48,
              onChanged: enabled ? (v) => audio.setBand(index, band.copyWith(gain: v)) : null,
            ),
          ),
        ),
        Tooltip(
          message: 'Change frequency and width',
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: enabled ? () => _editBand(context) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: Text(
                _freq(band.frequency),
                style: text.labelMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _editBand(BuildContext context) async {
    var f = band.frequency;
    var q = band.q;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Band ${index + 1}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Frequency: ${_freq(f)}Hz'),
              // Log scale: equal slider travel per octave.
              Slider(
                value: _log(f),
                min: _log(20),
                max: _log(20000),
                onChanged: (v) => setState(() => f = _exp(v)),
              ),
              Text('Width: ${q < 1 ? 'wide' : q > 3 ? 'narrow' : 'medium'} (Q ${q.toStringAsFixed(2)})'),
              Slider(value: q, min: 0.3, max: 8, onChanged: (v) => setState(() => q = v)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                f = defaultEqFrequencies[index];
                q = 1.41;
                Navigator.pop(context, true);
              },
              child: const Text('Default'),
            ),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')),
          ],
        ),
      ),
    );
    if (ok == true) await audio.setBand(index, band.copyWith(frequency: f.roundToDouble(), q: q));
  }

  static double _log(double f) => math.log(f);
  static double _exp(double v) => math.exp(v);
}
