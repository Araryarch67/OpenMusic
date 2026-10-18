import 'package:flutter/material.dart';

import '../../services/player_controller.dart';
import '../theme.dart';

/// "Local | YouTube Music" pills that switch what Home, Search and Library show.
class SourceSwitch extends StatelessWidget {
  const SourceSwitch({super.key, this.collapsed = false});

  /// Icon-only toggle for the narrow sidebar rail.
  final bool collapsed;

  static IconData iconFor(MusicSource s) =>
      s == MusicSource.local ? Icons.folder_open_rounded : Icons.cloud_queue_rounded;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    if (collapsed) {
      final next = c.source == MusicSource.local ? MusicSource.youtubeMusic : MusicSource.local;
      return Tooltip(
        message: 'Source: ${c.source.label} (switch to ${next.label})',
        child: IconButton(
          onPressed: () => c.setSource(next),
          icon: Icon(iconFor(c.source), color: AppColors.textPrimary),
        ),
      );
    }
    final text = Theme.of(context).textTheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in MusicSource.values)
          ChoiceChip(
            avatar: Icon(iconFor(s), size: 16, color: c.source == s ? Colors.black : AppColors.textSecondary),
            label: Text(s.label),
            labelStyle: text.labelLarge?.copyWith(
              color: c.source == s ? Colors.black : AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            selected: c.source == s,
            onSelected: (_) => c.setSource(s),
          ),
      ],
    );
  }
}
