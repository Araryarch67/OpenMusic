import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/audio_engine.dart';
import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/menus.dart';
import '../widgets/signal_path.dart';
import 'equalizer_page.dart';

/// Settings › Playback: the everyday sound options.
class PlaybackSettings extends StatelessWidget {
  const PlaybackSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final audio = c.audio;
    final shell = ShellScope.of(context);
    final muted = settingsMuted(context);
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final locked = audio.bitPerfect;
        String lockedNote(String normal) => locked ? 'Off while bit-perfect mode is on' : normal;
        return SettingsCard(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.radio_rounded),
              title: const Text('Autoplay'),
              subtitle: Text('When the queue ends, keep going with similar songs', style: muted),
              value: c.autoplay,
              onChanged: c.setAutoplay,
            ),
            if (AudioEngine.supported) ...[
              ListTile(
                leading: const Icon(Icons.equalizer_rounded),
                title: const Text('Equalizer'),
                subtitle: Text(lockedNote(audio.eqActive ? audio.eqPreset : 'Off'), style: muted),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => shell.open(const EqualizerPage()),
              ),
              SettingTile(
                icon: Icons.graphic_eq_rounded,
                title: const Text('Volume leveling'),
                subtitle: Text(
                  lockedNote('Plays songs at a similar loudness, using their ReplayGain tags'),
                  style: muted,
                ),
                control: OptionPicker<VolumeLeveling>(
                  value: audio.leveling,
                  onChanged: locked ? null : audio.setLeveling,
                  options: [for (final v in VolumeLeveling.values) (v, v.label)],
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.join_inner_rounded),
                title: const Text('Gapless playback'),
                subtitle: Text('No silence between songs of albums that flow into each other', style: muted),
                value: audio.gapless,
                onChanged: audio.setGapless,
              ),
              if (AudioEngine.hasCrossfeed)
                SettingTile(
                  icon: Icons.headphones_rounded,
                  title: const Text('Headphone crossfeed'),
                  subtitle: Text(lockedNote('Makes headphones sound more like speakers in a room'), style: muted),
                  control: SizedBox(
                    width: 200,
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
                          child: Text(
                            audio.crossfeed == 0 ? 'Off' : '${(audio.crossfeed * 100).round()}%',
                            style: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// Settings › Advanced audio: DACs and hi-fi setups, folded until opened.
class AdvancedAudioSettings extends StatelessWidget {
  const AdvancedAudioSettings({super.key});

  static Future<void> _pickImpulse(BuildContext context, AudioEngine audio) async {
    final messenger = ScaffoldMessenger.of(context);
    final file = (await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['wav', 'flac'],
      dialogTitle: 'Choose an impulse response',
    )).firstOrNull;
    final path = file?.path;
    if (file == null || path == null) return;
    try {
      await audio.setImpulse(File(path), name: file.name, into: await getApplicationSupportDirectory());
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t use that file: $e')));
    }
  }

  static const _rates = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000];

  @override
  Widget build(BuildContext context) {
    if (!AudioEngine.supported) return const SizedBox.shrink();
    final audio = PlayerScope.of(context).audio;
    final muted = settingsMuted(context);
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final locked = audio.bitPerfect;
        return SettingsCard(
          children: [
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                leading: const Icon(Icons.tune_rounded),
                title: const Text('Advanced audio'),
                subtitle: Text(
                  locked
                      ? 'Bit-perfect mode is on'
                      : AudioEngine.hasOutputChoice
                      ? 'Output device, bit-perfect, sample rate, room correction'
                      : 'Sample rate, resampler, buffer, signal path',
                  style: muted,
                ),
                shape: const Border(),
                collapsedShape: const Border(),
                onExpansionChanged: (open) {
                  if (open) audio.refreshDevices();
                },
                children: [
                  for (final row in [
                    if (AudioEngine.hasOutputChoice)
                      SettingTile(
                        icon: Icons.speaker_rounded,
                        title: const Text('Output device'),
                        subtitle: Text(
                          audio.deviceError ??
                              'Devices marked "direct" skip the system mixer: bit-perfect, but other apps go quiet',
                          style: audio.deviceError == null
                              ? muted
                              : muted?.copyWith(color: Theme.of(context).colorScheme.error),
                        ),
                        control: OptionPicker<String>(
                          maxWidth: 200,
                          value: audio.devices.any((d) => d.name == audio.device) ? audio.device : 'auto',
                          onChanged: audio.setDevice,
                          options: [
                            for (final d in audio.devices)
                              (d.name, d.direct ? '${d.description} (direct)' : d.description),
                          ],
                        ),
                      ),
                    if (AudioEngine.hasOutputChoice)
                      SwitchListTile(
                        secondary: const Icon(Icons.verified_outlined),
                        title: const Text('Bit-perfect mode'),
                        subtitle: Text(
                          'Sends the file to your DAC untouched: no equalizer, leveling, resampling or digital volume. '
                          '${AudioEngine.hasExclusiveMode ? 'Takes the device exclusively.' : 'Takes over your DAC so the system mixer can\'t resample. Meanwhile other apps play through another output.'}',
                          style: muted,
                        ),
                        value: audio.bitPerfect,
                        onChanged: audio.setBitPerfect,
                      ),
                    if (AudioEngine.hasExclusiveMode)
                      SwitchListTile(
                        secondary: const Icon(Icons.lock_outline_rounded),
                        title: const Text('Exclusive mode'),
                        subtitle: Text(
                          'Takes over the device so the system mixer can\'t resample. '
                          'The DAC switches to each song\'s sample rate.',
                          style: muted,
                        ),
                        value: audio.exclusive || locked,
                        onChanged: locked ? null : audio.setExclusive,
                      ),
                    if (AudioEngine.hasRoomCorrection)
                      SettingTile(
                        icon: Icons.surround_sound_rounded,
                        title: const Text('Room correction'),
                        subtitle: Text(
                          locked
                              ? 'Off while bit-perfect mode is on'
                              : audio.impulseName == null
                              ? 'Load an impulse response (WAV or FLAC, e.g. made with REW) to correct your room or headphones'
                              : audio.impulseName!,
                          style: muted,
                        ),
                        control: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: locked ? null : () => _pickImpulse(context, audio),
                              child: Text(audio.impulseName == null ? 'Choose file' : 'Change'),
                            ),
                            Switch(
                              value: audio.convolution && !locked,
                              onChanged: locked || audio.impulsePath == null ? null : audio.setConvolution,
                            ),
                          ],
                        ),
                      ),
                    SettingTile(
                      icon: Icons.multiline_chart_rounded,
                      title: const Text('Output sample rate'),
                      subtitle: Text(
                        locked
                            ? 'Follows each song while bit-perfect mode is on'
                            : 'Follow the song, or convert everything to one rate',
                        style: muted,
                      ),
                      control: OptionPicker<int>(
                        value: locked ? 0 : audio.outputRate ?? 0,
                        onChanged: locked ? null : (v) => audio.setOutputRate(v == 0 ? null : v),
                        options: [(0, 'Follow the song'), for (final r in _rates) (r, SignalPath.formatRate(r))],
                      ),
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.high_quality_outlined),
                      title: const Text('High-quality resampler'),
                      subtitle: Text(
                        'SoX-grade conversion whenever the rate has to change (slightly more CPU)',
                        style: muted,
                      ),
                      value: audio.hqResampler && !locked,
                      onChanged: locked ? null : audio.setHqResampler,
                    ),
                    SettingTile(
                      icon: Icons.timer_outlined,
                      title: const Text('Buffer'),
                      subtitle: Text('Raise it if you hear crackles or dropouts', style: muted),
                      control: OptionPicker<BufferSize>(
                        value: audio.buffer,
                        onChanged: audio.setBuffer,
                        options: [
                          for (final b in BufferSize.values) (b, '${b.label} (${(b.seconds * 1000).round()} ms)'),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.account_tree_outlined),
                      title: const Text('Signal path'),
                      subtitle: Text('See exactly what happens to the song you\'re playing', style: muted),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showSignalPath(context),
                    ),
                  ]) ...[const SettingsDivider(), row],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

TextStyle? settingsMuted(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary);

/// A titled group of settings.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        ),
        child,
      ],
    ),
  );
}

/// Rows on a rounded panel, with thin lines between them.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.elevated,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: ListTileTheme(
      iconColor: AppColors.textSecondary,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      child: Column(
        children: [
          for (final (i, row) in children.indexed) ...[if (i > 0) const SettingsDivider(), row],
        ],
      ),
    ),
  );
}

class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) => const Divider(height: 1, thickness: 1, indent: 58, color: Color(0x0FFFFFFF));
}

/// A settings row whose control sits on the right, or under the text when
/// the window is too narrow for both side by side.
class SettingTile extends StatelessWidget {
  const SettingTile({super.key, required this.title, this.subtitle, required this.control, this.icon});

  final IconData? icon;
  final Widget title;
  final Widget? subtitle;
  final Widget control;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth >= 520
        ? ListTile(leading: icon == null ? null : Icon(icon), title: title, subtitle: subtitle, trailing: control)
        : ListTile(
            leading: icon == null ? null : Icon(icon),
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
