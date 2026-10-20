import 'package:flutter/material.dart';

import '../../services/appearance.dart';
import '../theme.dart';
import '../widgets/menus.dart';
import 'sound_settings.dart';

/// Settings › Appearance: accent, cover colours, frosted glass, window
/// transparency and text size.
class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final look = Appearance.instance;
    final muted = settingsMuted(context);
    return ListenableBuilder(
      listenable: look,
      builder: (context, _) => SettingsCard(
        children: [
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Accent colour'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [for (final a in AccentChoice.values) _Swatch(choice: a, selected: look.accent == a)],
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.format_color_fill_rounded),
            title: const Text('Colours from cover art'),
            subtitle: Text('Tint pages and the player with the colour of what\'s playing', style: muted),
            value: look.coverColors,
            onChanged: look.setCoverColors,
          ),
          SettingTile(
            icon: Icons.wallpaper_rounded,
            title: const Text('Now playing background'),
            subtitle: Text('Behind the cover on the full player (phones)', style: muted),
            control: OptionPicker<NowPlayingBackground>(
              value: look.nowPlaying,
              onChanged: look.setNowPlaying,
              options: [for (final v in NowPlayingBackground.values) (v, v.label)],
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.blur_on_rounded),
            title: const Text('Frosted glass'),
            subtitle: Text('See-through, blurred mini player and tab bar. Uses a little more GPU', style: muted),
            value: look.glass,
            onChanged: look.setGlass,
          ),
          if (look.glass)
            _SliderTile(
              icon: Icons.lens_blur_rounded,
              title: 'Blur strength',
              value: look.blur,
              min: 4,
              max: 48,
              label: (v) => v.round().toString(),
              onChanged: look.setBlur,
            ),
          if (Appearance.hasWindowOpacity)
            _SliderTile(
              icon: Icons.opacity_rounded,
              title: 'Window opacity',
              subtitle: 'Below 100% the desktop shows through; compositors that blur windows (Hyprland, KDE) blur it',
              value: look.windowOpacity,
              min: 0.5,
              max: 1,
              label: (v) => '${(v * 100).round()}%',
              onChanged: look.setWindowOpacity,
            ),
          SettingTile(
            icon: Icons.format_size_rounded,
            title: const Text('Text size'),
            control: OptionPicker<double>(
              value: look.textScale,
              onChanged: look.setTextScale,
              options: const [(0.9, 'Small'), (1.0, 'Default'), (1.15, 'Large'), (1.3, 'Largest')],
            ),
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.choice, required this.selected});

  final AccentChoice choice;
  final bool selected;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: choice.label,
    child: Semantics(
      button: true,
      selected: selected,
      label: '${choice.label} accent',
      child: InkResponse(
        onTap: () => Appearance.instance.setAccent(choice),
        radius: 22,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: choice.color,
            shape: BoxShape.circle,
            border: Border.all(color: selected ? AppColors.textPrimary : Colors.transparent, width: 2),
          ),
          child: selected ? Icon(Icons.check_rounded, size: 18, color: choice.onColor) : null,
        ),
      ),
    ),
  );
}

/// A slider that previews while dragging and saves when let go, so a drag
/// doesn't restyle the whole app on every frame.
class _SliderTile extends StatefulWidget {
  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final String Function(double) label;
  final ValueChanged<double> onChanged;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final v = _dragging ?? widget.value;
    final muted = settingsMuted(context);
    return ListTile(
      leading: Icon(widget.icon),
      title: Row(
        children: [
          Expanded(child: Text(widget.title)),
          Text(widget.label(v), style: muted),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.subtitle != null) Text(widget.subtitle!, style: muted),
          Slider(
            value: v,
            min: widget.min,
            max: widget.max,
            onChanged: (x) => setState(() => _dragging = x),
            onChangeEnd: (x) {
              setState(() => _dragging = null);
              widget.onChanged(x);
            },
          ),
        ],
      ),
    );
  }
}
