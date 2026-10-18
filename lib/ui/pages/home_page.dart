import 'package:flutter/material.dart';

import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/shelf.dart';
import 'collection_page.dart';
import 'downloads_page.dart';
import 'youtube_music_page.dart';
import '../widgets/source_switch.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static String _greeting() {
    final h = DateTime.now().hour;
    return h < 5
        ? 'Good night'
        : h < 12
        ? 'Good morning'
        : h < 18
        ? 'Good afternoon'
        : 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;

    if (c.source == MusicSource.youtubeMusic) return const YoutubeMusicHome();

    if (c.library.isEmpty) {
      return PageScaffold(
        slivers: [
          if (shell.compact)
            SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.fromLTRB(pad, 0, pad, 0), child: const SourceSwitch()),
            ),
          SliverFillRemaining(hasScrollBody: false, child: EmptyLibrary(greeting: _greeting())),
        ],
      );
    }

    final albums = c.albums;
    final artists = c.artists;
    final recent = c.recentlyPlayed;
    final quickPicks = <Widget>[
      QuickTile(
        title: 'All Songs',
        leading: CoverMosaic(tracks: c.allSongs.tracks, radius: 0),
        onTap: () => shell.openCollection(c.allSongs),
        onPlay: () => c.playCollection(c.allSongs),
      ),
      for (final a in albums.take(3))
        QuickTile(
          title: a.title,
          leading: Artwork(track: a.cover),
          onTap: () => shell.openCollection(a),
          onPlay: () => c.playCollection(a),
        ),
      for (final t in recent.where((t) => t.album == null || !albums.take(3).any((a) => a.title == t.album)).take(4))
        QuickTile(
          title: t.title,
          leading: Artwork(track: t),
          onTap: () => c.playList(recent, recent.indexOf(t), from: 'Recently played'),
        ),
    ].take(shell.compact ? 6 : 8).toList();

    return AccentBuilder(
      track: c.currentTrack ?? c.recentlyPlayed.firstOrNull,
      builder: (context, accent) => PageScaffold(
        gradientColor: accent,
        actions: [
          if (c.scanning)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          if (shell.compact) ...[const DownloadsButton(), _AddMenu(shell: shell)],
        ],
        slivers: [
          if (shell.compact)
            SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.fromLTRB(pad, 0, pad, 16), child: const SourceSwitch()),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
              child: Text(
                _greeting(),
                style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: shell.compact ? 260 : 360,
                mainAxisExtent: shell.compact ? 56 : 64,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: quickPicks.length,
              itemBuilder: (_, i) => quickPicks[i],
            ),
          ),
          if (recent.isNotEmpty)
            ..._shelf(context, 'Recently played', [
              for (final (i, t) in recent.indexed)
                MediaCard(
                  track: t,
                  title: t.title,
                  subtitle: t.artist,
                  onTap: () => c.playList(recent, i, from: 'Recently played'),
                  onPlay: () => c.playList(recent, i, from: 'Recently played'),
                ),
            ]),
          if (albums.isNotEmpty)
            ..._shelf(context, 'Your albums', [
              for (final a in albums)
                MediaCard(
                  track: a.cover,
                  title: a.title,
                  subtitle: a.subtitle,
                  onTap: () => shell.openCollection(a),
                  onPlay: () => c.playCollection(a),
                ),
            ]),
          if (artists.isNotEmpty)
            ..._shelf(context, 'Artists', [
              for (final a in artists)
                MediaCard(
                  track: a.cover,
                  title: a.title,
                  subtitle: 'Artist',
                  circle: true,
                  onTap: () => shell.openCollection(a),
                  onPlay: () => c.playCollection(a),
                ),
            ]),
          ..._shelf(context, 'Recently added', [
            for (final t in c.recentlyAdded.take(20))
              MediaCard(
                track: t,
                title: t.title,
                subtitle: t.artist,
                onTap: () => c.playList(c.recentlyAdded, c.recentlyAdded.indexOf(t), from: 'Recently added'),
                onPlay: () => c.playList(c.recentlyAdded, c.recentlyAdded.indexOf(t), from: 'Recently added'),
              ),
          ], onShowAll: () => shell.open(CollectionPage(collection: c.allSongs))),
        ],
      ),
    );
  }

  List<Widget> _shelf(BuildContext context, String title, List<Widget> cards, {VoidCallback? onShowAll}) => [
    SliverToBoxAdapter(
      child: Shelf(title: title, cards: cards, onShowAll: onShowAll),
    ),
  ];
}

/// Compact "jump back in" tile: artwork on the left, bold title, play button on hover.
class QuickTile extends StatefulWidget {
  const QuickTile({super.key, required this.title, required this.leading, required this.onTap, this.onPlay});

  final String title;
  final Widget leading;
  final VoidCallback onTap;
  final VoidCallback? onPlay;

  @override
  State<QuickTile> createState() => _QuickTileState();
}

class _QuickTileState extends State<QuickTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: _hover ? const Color(0x29FFFFFF) : AppColors.tile,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          hoverColor: Colors.transparent,
          child: Row(
            children: [
              AspectRatio(aspectRatio: 1, child: widget.leading),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (widget.onPlay != null)
                AnimatedOpacity(
                  opacity: _hover ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: PlayButton(
                      playing: false,
                      size: 36,
                      color: AppColors.accent,
                      iconColor: AppColors.onAccent,
                      onPressed: widget.onPlay,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddMenu extends StatelessWidget {
  const _AddMenu({required this.shell});

  final ShellScope shell;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VoidCallback>(
      tooltip: 'Add music',
      icon: const Icon(Icons.add_rounded),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: shell.addFiles,
          child: const ListTile(leading: Icon(Icons.audio_file_outlined), title: Text('Add songs')),
        ),
        PopupMenuItem(
          value: shell.importFromYoutube,
          child: const ListTile(leading: Icon(Icons.add_link_rounded), title: Text('Import from YouTube')),
        ),
      ],
    );
  }
}

class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({super.key, this.greeting});

  final String? greeting;

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.library_music_outlined, size: 56, color: AppColors.textSecondary),
              const SizedBox(height: 24),
              if (greeting != null) Text(greeting!, style: text.titleMedium?.copyWith(color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              Text(
                'No music yet',
                textAlign: TextAlign.center,
                style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.8),
              ),
              const SizedBox(height: 12),
              Text(
                'Add audio files from this device. Albums, artists and cover art come from the files\' tags.',
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.textPrimary,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      textStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    onPressed: shell.addFiles,
                    icon: const Icon(Icons.audio_file_rounded),
                    label: const Text('Add songs'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.textMuted),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      textStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    onPressed: shell.importFromYoutube,
                    icon: const Icon(Icons.add_link_rounded),
                    label: const Text('From YouTube'),
                  ),
                  if (shell.addFolder != null)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.textMuted),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        textStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      onPressed: shell.addFolder,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Add a folder'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
