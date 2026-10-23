import 'package:flutter/material.dart';

import '../../services/player_controller.dart';
import '../../services/youtube_importer.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/page_scaffold.dart';

/// Progress and history of YouTube imports.
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Only the downloads matter here, not every change of what's playing.
    final c = PlayerScope.read(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    return ListenableBuilder(
      listenable: c.youtube,
      builder: (context, _) {
        final jobs = c.youtube.jobs;
        final hasFinished = jobs.any((j) => !j.isActive);
        return PageScaffold(
          title: 'Downloads',
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    Text('Downloads', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.inverse,
                        foregroundColor: AppColors.onInverse,
                      ),
                      onPressed: shell.importFromYoutube,
                      icon: const Icon(Icons.add_link_rounded),
                      label: const Text('Import from YouTube'),
                    ),
                    if (hasFinished)
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
                        onPressed: c.youtube.clearFinished,
                        child: const Text('Clear finished'),
                      ),
                  ],
                ),
              ),
            ),
            if (jobs.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: pad, vertical: 8),
                  child: Text(
                    'Nothing downloading. Paste a YouTube video or playlist link to add its audio to your library.',
                    style: text.bodyLarge?.copyWith(color: AppColors.textSecondary),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: shell.compact ? 8 : 16),
                sliver: SliverList.builder(
                  itemCount: jobs.length,
                  itemBuilder: (context, i) => _JobRow(job: jobs[i]),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job});

  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    final text = Theme.of(context).textTheme;
    final status = switch (job.status) {
      DownloadStatus.queued => 'Waiting…',
      DownloadStatus.downloading =>
        job.quality == null
            ? 'Preparing…'
            : [
                job.quality,
                if (job.totalBytes != null) '${formatBytes(job.receivedBytes)} of ${formatBytes(job.totalBytes!)}',
                if (job.bytesPerSecond != null) '${formatBytes(job.bytesPerSecond!)}/s',
                if (job.eta case final eta?) formatEta(eta),
              ].join(' • '),
      DownloadStatus.done => [
        'Added to library',
        ?job.quality,
        if (job.totalBytes != null) formatBytes(job.totalBytes!),
      ].join(' • '),
      DownloadStatus.failed => job.error ?? 'Failed',
      DownloadStatus.cancelled => 'Cancelled',
    };
    final statusColor = switch (job.status) {
      DownloadStatus.failed => Theme.of(context).colorScheme.error,
      DownloadStatus.done => AppColors.accent,
      _ => AppColors.textSecondary,
    };
    final track = job.track;

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      hoverColor: AppColors.tile,
      onTap: track == null ? null : () => c.playList([track], 0, from: 'From YouTube'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 96,
                height: 54,
                child: Image.network(
                  job.thumbnailUrl,
                  // Decoded at the size shown, not YouTube's 480 or 1280 px.
                  cacheWidth: (96 * MediaQuery.devicePixelRatioOf(context)).round(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(color: AppColors.hover),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: statusColor),
                  ),
                  if (job.status == DownloadStatus.downloading) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: job.quality == null ? null : job.progress,
                      minHeight: 3,
                      color: AppColors.textPrimary,
                      backgroundColor: AppColors.hover,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            switch (job.status) {
              DownloadStatus.queued || DownloadStatus.downloading => IconButton(
                tooltip: 'Cancel',
                onPressed: () => c.youtube.cancel(job),
                icon: const Icon(Icons.close_rounded),
              ),
              DownloadStatus.failed || DownloadStatus.cancelled => IconButton(
                tooltip: 'Retry',
                onPressed: () => c.youtube.retry(job),
                icon: const Icon(Icons.refresh_rounded),
              ),
              DownloadStatus.done => IconButton(
                tooltip: 'Play',
                onPressed: () => c.playList([track!], 0, from: 'From YouTube'),
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            },
          ],
        ),
      ),
    );
  }
}

/// Toolbar button that shows a progress ring while imports are running.
class DownloadsButton extends StatelessWidget {
  const DownloadsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    final shell = ShellScope.of(context);
    return ListenableBuilder(
      listenable: c.youtube,
      builder: (context, _) {
        final progress = c.youtube.activeProgress;
        return IconButton(
          tooltip: progress == null ? 'Downloads' : 'Downloading ${c.youtube.activeCount}',
          onPressed: shell.openDownloads,
          icon: progress == null
              ? const Icon(Icons.download_rounded)
              : SizedBox.square(
                  dimension: 22,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: progress == 0 ? null : progress,
                        strokeWidth: 2.2,
                        color: AppColors.accent,
                        backgroundColor: AppColors.hover,
                      ),
                      Icon(Icons.arrow_downward_rounded, size: 13, color: AppColors.textPrimary),
                    ],
                  ),
                ),
        );
      },
    );
  }
}
