import 'dart:io';

import 'package:flutter/material.dart';

import '../services/cast.dart';
import '../services/player_controller.dart';
import 'shell_scope.dart';
import 'theme.dart';

/// The "Play on" button: lights up while a TV or speaker is playing.
class CastButton extends StatelessWidget {
  const CastButton({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final target = c.cast.target;
    return IconButton(
      tooltip: target == null ? 'Play on a device' : 'Playing on ${target.name}',
      color: target == null ? color : AppColors.accent,
      onPressed: () => showCastPicker(context),
      icon: Icon(target == null ? Icons.cast_rounded : Icons.cast_connected_rounded, size: size),
    );
  }
}

/// Lists this device and the TVs / speakers on the network; picking one moves
/// the music there. Bottom sheet on phones, dialog elsewhere.
Future<void> showCastPicker(BuildContext context) {
  final controller = PlayerScope.read(context);
  final body = PlayerScope(controller: controller, child: const _CastPicker());
  if (ShellScope.of(context).compact) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: AppColors.elevated,
      builder: (_) => SafeArea(child: body),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: AppColors.elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: body),
    ),
  );
}

class _CastPicker extends StatefulWidget {
  const _CastPicker();

  @override
  State<_CastPicker> createState() => _CastPickerState();
}

class _CastPickerState extends State<_CastPicker> {
  CastTarget? _connecting;

  @override
  void initState() {
    super.initState();
    // After this frame: the search notifies listeners, which can't happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) PlayerScope.read(context).cast.search();
    });
  }

  Future<void> _pick(CastTarget? renderer) async {
    final c = PlayerScope.read(context);
    setState(() => _connecting = renderer);
    await c.castTo(renderer);
    if (!mounted) return;
    setState(() => _connecting = null);
    // Stay open after a failure: the message shows and another can be tried.
    if (c.cast.target == renderer) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final cast = c.cast;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textSecondary);
    final here = Platform.isAndroid || Platform.isIOS ? 'This phone' : 'This computer';

    Widget tile({
      required IconData icon,
      required String name,
      required bool selected,
      required VoidCallback onTap,
      CastTarget? renderer,
    }) {
      final busy = renderer != null && _connecting == renderer;
      return ListTile(
        leading: Icon(icon, color: selected ? AppColors.accent : null),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: selected ? TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600) : null,
        ),
        trailing: busy
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : selected
            ? Icon(Icons.check_rounded, color: AppColors.accent)
            : null,
        onTap: _connecting != null || selected ? null : onTap,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Text('Play on', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        ),
        tile(
          icon: Platform.isAndroid || Platform.isIOS ? Icons.smartphone_rounded : Icons.computer_rounded,
          name: here,
          selected: !c.casting,
          onTap: () => _pick(null),
        ),
        for (final r in cast.devices)
          tile(
            icon: r is AirPlayTarget ? Icons.speaker_group_rounded : Icons.speaker_rounded,
            name: r.name,
            selected: cast.target == r,
            renderer: r,
            onTap: () => _pick(r),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: cast.searching
              ? Row(
                  children: [
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Text('Looking for TVs and speakers…', style: muted),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Text(
                        cast.devices.isEmpty
                            ? 'No TVs or speakers found. They need to be on and on the same Wi-Fi.'
                            : 'Works with TVs, speakers and receivers that support DLNA or AirPlay.',
                        style: muted,
                      ),
                    ),
                    TextButton(onPressed: cast.search, child: const Text('Search again')),
                  ],
                ),
        ),
      ],
    );
  }
}
