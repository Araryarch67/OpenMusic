import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import 'controls.dart';

/// One song in a list: number (or play icon on hover), cover, title, album, duration.
class TrackRow extends StatefulWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.onTap,
    this.index,
    this.showAlbum = true,
    this.showArtwork = true,
  });

  final Track track;
  final VoidCallback onTap;

  /// 1-based position shown in the leading column; null hides the column.
  final int? index;
  final bool showAlbum;
  final bool showArtwork;

  @override
  State<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<TrackRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final t = widget.track;
    final isCurrent = c.currentTrack?.id == t.id;
    final wide = !shell.compact;

    Widget? leading;
    if (widget.index != null && wide) {
      leading = SizedBox(
        width: 32,
        child: Center(
          child: isCurrent && !_hover
              ? EqualizerIcon(playing: c.isPlaying, size: 14)
              : _hover
              ? Icon(
                  isCurrent && c.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: AppColors.textPrimary,
                  size: 20,
                )
              : Text(
                  '${widget.index}',
                  style: text.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: _hover ? AppColors.tile : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: Colors.transparent,
          onTap: isCurrent && wide && _hover ? c.togglePlay : widget.onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: wide ? 12 : 4, vertical: 6),
            child: Row(
              children: [
                if (leading != null) ...[leading, const SizedBox(width: 12)],
                if (widget.showArtwork) ...[Artwork(track: t, size: wide ? 40 : 48), const SizedBox(width: 12)],
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge?.copyWith(
                          color: isCurrent ? AppColors.accent : AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (isCurrent && !wide) ...[
                            EqualizerIcon(playing: c.isPlaying, size: 10),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              t.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (wide && widget.showAlbum && shell.width > 900) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 4,
                    child: Text(
                      t.album ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
                if (wide)
                  SizedBox(
                    width: 56,
                    child: Text(
                      t.duration == null ? '' : formatDuration(t.duration),
                      textAlign: TextAlign.right,
                      style: text.bodyMedium?.copyWith(
                        color: AppColors.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                _TrackMenu(track: t, visible: !wide || _hover),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackMenu extends StatelessWidget {
  const _TrackMenu({required this.track, required this.visible});

  final Track track;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    final shell = ShellScope.of(context);
    final artist = c.artistNamed(track.artist);
    final album = c.albumOf(track);
    return Opacity(
      opacity: visible ? 1 : 0,
      child: PopupMenuButton<void>(
        tooltip: 'More options for ${track.title}',
        icon: const Icon(Icons.more_horiz_rounded),
        itemBuilder: (_) => [
          if (artist != null)
            PopupMenuItem(
              onTap: () => shell.openCollection(artist),
              child: const ListTile(leading: Icon(Icons.person_outline_rounded), title: Text('Go to artist')),
            ),
          if (album != null)
            PopupMenuItem(
              onTap: () => shell.openCollection(album),
              child: const ListTile(leading: Icon(Icons.album_outlined), title: Text('Go to album')),
            ),
          if (track.isRemote)
            PopupMenuItem(
              onTap: () => c.youtube.enqueueTracks([track]),
              child: const ListTile(leading: Icon(Icons.download_rounded), title: Text('Download')),
            )
          else
            PopupMenuItem(
              onTap: () => c.removeTrack(track),
              child: const ListTile(
                leading: Icon(Icons.remove_circle_outline_rounded),
                title: Text('Remove from library'),
              ),
            ),
        ],
      ),
    );
  }
}
