import 'package:flutter/material.dart';

import '../../services/audio_engine.dart';
import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/signal_path.dart';
import 'equalizer_page.dart';

/// The "Sound" part of Settings: everyday options up top, hi-fi ones folded away.
class SoundSettings extends StatelessWidget {
  const SoundSettings({super.key});

  static const _rates = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000];

  @override
  Widget build(BuildContext context) {
    if (!AudioEngine.supported) return const SizedBox.shrink();
    final audio = PlayerScope.of(context).audio;
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textSecondary);
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final locked = audio.bitPerfect;
        String? lockedNote(String normal) => locked ? 'Off while bit-perfect mode is on' : normal;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
              child: Text('Sound', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
            ListTile(
              title: const Text('Equalizer'),
              subtitle: Text(lockedNote(audio.eqActive ? audio.eqPreset : 'Off')!, style: muted),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => shell.open(const EqualizerPage()),
            ),
            SettingTile(
              title: const Text('Volume leveling'),
              subtitle: Text(
                lockedNote('Plays songs at a similar loudness, using their ReplayGain tags')!,
                style: muted,
              ),
              control: DropdownButton<VolumeLeveling>(
                value: audio.leveling,
                underline: const SizedBox.shrink(),
                onChanged: locked ? null : (v) => audio.setLeveling(v!),
                items: [for (final v in VolumeLeveling.values) DropdownMenuItem(value: v, child: Text(v.label))],
              ),
            ),
            SwitchListTile(
              title: const Text('Gapless playback'),
              subtitle: Text('No silence between songs of albums that flow into each other', style: muted),
              value: audio.gapless,
              onChanged: audio.setGapless,
            ),
            SettingTile(
              title: const Text('Headphone crossfeed'),
              subtitle: Text(lockedNote('Makes headphones sound more like speakers in a room')!, style: muted),
              control: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: audio.crossfeed,
                        divisions: 10,
                        onChanged: locked ? null : audio.setCrossfeed,
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(audio.crossfeed == 0 ? 'Off' : '${(audio.crossfeed * 100).round()}%', style: muted),
                    ),
                  ],
                ),
              ),
            ),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: const Text('Advanced audio'),
                subtitle: Text('For DACs and hi-fi setups', style: muted),
                onExpansionChanged: (open) {
                  if (open) audio.refreshDevices();
                },
                children: [
                  SettingTile(
                    title: const Text('Output device'),
                    subtitle: Text(
                      'Devices marked "direct" skip the system mixer: bit-perfect, but other apps go quiet',
                      style: muted,
                    ),
                    control: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: audio.devices.any((d) => d.name == audio.device) ? audio.device : 'auto',
                        underline: const SizedBox.shrink(),
                        onChanged: (v) => audio.setDevice(v!),
                        items: [
                          for (final d in audio.devices)
                            DropdownMenuItem(
                              value: d.name,
                              child: Text(
                                d.direct ? '${d.description} (direct)' : d.description,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Bit-perfect mode'),
                    subtitle: Text(
                      'Sends the file to your DAC untouched: no equalizer, leveling, resampling or digital volume. '
                      '${AudioEngine.hasExclusiveMode ? 'Takes the device exclusively.' : 'Pick a "direct" output device for the full effect.'}',
                      style: muted,
                    ),
                    value: audio.bitPerfect,
                    onChanged: audio.setBitPerfect,
                  ),
                  if (AudioEngine.hasExclusiveMode)
                    SwitchListTile(
                      title: const Text('Exclusive mode'),
                      subtitle: Text(
                        'Takes over the device so the system mixer can\'t resample. '
                        'The DAC switches to each song\'s sample rate.',
                        style: muted,
                      ),
                      value: audio.exclusive || locked,
                      onChanged: locked ? null : audio.setExclusive,
                    ),
                  SettingTile(
                    title: const Text('Output sample rate'),
                    subtitle: Text(
                      locked
                          ? 'Follows each song while bit-perfect mode is on'
                          : 'Follow the song, or convert everything to one rate',
                      style: muted,
                    ),
                    control: DropdownButton<int>(
                      value: locked ? 0 : audio.outputRate ?? 0,
                      underline: const SizedBox.shrink(),
                      onChanged: locked ? null : (v) => audio.setOutputRate(v == 0 ? null : v),
                      items: [
                        const DropdownMenuItem(value: 0, child: Text('Follow the song')),
                        for (final r in _rates) DropdownMenuItem(value: r, child: Text(SignalPath.formatRate(r))),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('High-quality resampler'),
                    subtitle: Text(
                      'SoX-grade conversion whenever the rate has to change (slightly more CPU)',
                      style: muted,
                    ),
                    value: audio.hqResampler && !locked,
                    onChanged: locked ? null : audio.setHqResampler,
                  ),
                  SettingTile(
                    title: const Text('Buffer'),
                    subtitle: Text('Raise it if you hear crackles or dropouts', style: muted),
                    control: DropdownButton<BufferSize>(
                      value: audio.buffer,
                      underline: const SizedBox.shrink(),
                      onChanged: (v) => audio.setBuffer(v!),
                      items: [
                        for (final b in BufferSize.values)
                          DropdownMenuItem(value: b, child: Text('${b.label} (${(b.seconds * 1000).round()} ms)')),
                      ],
                    ),
                  ),
                  ListTile(
                    title: const Text('Signal path'),
                    subtitle: Text('See exactly what happens to the song you\'re playing', style: muted),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => showSignalPath(context),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A settings row whose control sits on the right, or under the text when
/// the window is too narrow for both side by side.
class SettingTile extends StatelessWidget {
  const SettingTile({super.key, required this.title, this.subtitle, required this.control});

  final Widget title;
  final Widget? subtitle;
  final Widget control;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth >= 520
        ? ListTile(title: title, subtitle: subtitle, trailing: control)
        : ListTile(
            title: title,
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?subtitle,
                Align(alignment: Alignment.centerLeft, child: control),
              ],
            ),
          ),
  );
}
