import 'package:flutter/material.dart';

import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/track_row.dart';

class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final current = c.currentTrack;
    final upNext = c.upNext;
    final pad = shell.compact ? 16.0 : 24.0;
    final hPad = EdgeInsets.symmetric(horizontal: shell.compact ? 12 : 16);

    return PageScaffold(
      title: 'Queue',
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
            child: Text('Queue', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
        ),
        if (current == null)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(pad),
              child: Text(
                'Nothing playing yet. Pick an album, artist or song to fill the queue.',
                style: text.bodyLarge?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          )
        else ...[
          const SliverToBoxAdapter(child: SectionTitle('Now playing')),
          SliverPadding(
            padding: hPad,
            sliver: SliverToBoxAdapter(
              child: TrackRow(track: current, index: 1, onTap: c.togglePlay),
            ),
          ),
          if (upNext.isNotEmpty) ...[
            SectionTitleSliver(title: c.playingFrom == null ? 'Next up' : 'Next from: ${c.playingFrom}'),
            SliverPadding(
              padding: hPad,
              sliver: SliverList.builder(
                itemCount: upNext.length,
                itemBuilder: (context, i) =>
                    TrackRow(track: upNext[i], index: i + 2, onTap: () => c.playQueueItem(upNext[i])),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class SectionTitleSliver extends StatelessWidget {
  const SectionTitleSliver({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(child: SectionTitle(title));
}
