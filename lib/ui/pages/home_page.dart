import 'package:flutter/material.dart';

import '../../services/player_controller.dart';
import '../../services/youtube_music_account.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/shelf.dart';
import 'downloads_page.dart';
import 'youtube_music_page.dart';
import '../widgets/menus.dart';

/// One Home for everything: your files, your OpenMusic playlists and your
/// YouTube Music library side by side, then YouTube Music's own shelves.
/// Streamed songs carry a cloud mark; everything else plays offline.
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
    final account = c.ytMusic;
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => FutureBuilder<YoutubeMusicLibrary?>(
        future: account.isSignedIn
            ? account.library().then<YoutubeMusicLibrary?>((l) => l, onError: (Object _) => null)
            : Future.value(null),
        builder: (context, snap) => _build(context, c, snap.data),
      ),
    );
  }

  Widget _build(BuildContext context, PlayerController c, YoutubeMusicLibrary? online) {
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    final account = c.ytMusic;

    final albums = c.albums;
    final artists = c.artists;
    final recent = c.recentlyPlayed;
    final liked = online == null || online.liked.isEmpty ? null : likedCollection(online.liked);
    final playlists = c.playlists;
    final remotePlaylists = online?.playlists ?? const <RemotePlaylist>[];

    final quickPicks = <Widget>[
      if (c.library.isNotEmpty)
        QuickTile(
          title: 'All Songs',
          leading: CoverMosaic(tracks: c.allSongs.tracks, radius: 0),
          onTap: () => shell.openCollection(c.allSongs),
          onPlay: () => c.playCollection(c.allSongs),
        ),
      if (liked != null)
        QuickTile(
          title: 'Liked music',
          leading: CoverMosaic(tracks: liked.tracks, radius: 0),
          onTap: () => shell.openCollection(liked),
          onPlay: () => c.playCollection(liked),
        ),
      for (final p in playlists.take(3))
        QuickTile(
          title: p.name,
          leading: CoverMosaic(tracks: p.tracks, radius: 0),
          onTap: () => shell.openCollection(c.playlistCollection(p)),
          onPlay: p.tracks.isEmpty ? null : () => c.playCollection(c.playlistCollection(p)),
        ),
      for (final p in remotePlaylists.take(3))
        QuickTile(
          title: p.title,
          leading: Artwork(track: playlistCover(p), radius: 0),
          onTap: () => openRemotePlaylist(context, p),
        ),
      for (final a in albums.take(3))
        QuickTile(
          title: a.title,
          leading: Artwork(track: a.cover),
          onTap: () => shell.openCollection(a),
          onPlay: () => c.playCollection(a),
        ),
    ].take(shell.compact ? 6 : 8).toList();

    return AccentBuilder(
      track: c.currentTrack ?? recent.firstOrNull,
      builder: (context, accent) => PageScaffold(
        gradientColor: accent,
        actions: [
          if (c.scanning)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              account.discover(refresh: true);
              if (account.isSignedIn) account.library(refresh: true);
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (shell.compact) ...[const DownloadsButton(), _AddMenu(shell: shell)],
        ],
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
              child: Text(
                _greeting(),
                style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8),
              ),
            ),
          ),
          if (quickPicks.isNotEmpty)
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
          if (!account.isSignedIn) const SliverToBoxAdapter(child: SignInBanner()),
          if (recent.isNotEmpty)
            ..._shelf(context, 'Recently played', [
              for (final (i, t) in recent.indexed)
                MediaCard(
                  track: t,
                  title: t.title,
                  subtitle: t.artist,
                  online: !c.isOffline(t),
                  onTap: () => c.playList(recent, i, from: 'Recently played'),
                  onPlay: () => c.playList(recent, i, from: 'Recently played'),
                ),
            ]),
          if (playlists.isNotEmpty || remotePlaylists.isNotEmpty)
            ..._shelf(context, 'Your playlists', [
              for (final p in playlists)
                MediaCard(
                  track: p.tracks.firstOrNull,
                  title: p.name,
                  subtitle: 'OpenMusic • ${p.tracks.length} songs',
                  onTap: () => shell.openCollection(c.playlistCollection(p)),
                  onPlay: p.tracks.isEmpty ? null : () => c.playCollection(c.playlistCollection(p)),
                ),
              for (final p in remotePlaylists)
                MediaCard(
                  track: playlistCover(p),
                  title: p.title,
                  subtitle: p.count == 0 ? 'YouTube Music' : 'YouTube Music • ${p.count} songs',
                  online: true,
                  onTap: () => openRemotePlaylist(context, p),
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
          if (c.library.isEmpty) const SliverToBoxAdapter(child: _AddYourMusic()),
          const DiscoverShelves(),
          if (c.library.isNotEmpty)
            ..._shelf(context, 'Recently added', [
              for (final t in c.recentlyAdded.take(20))
                MediaCard(
                  track: t,
                  title: t.title,
                  subtitle: t.artist,
                  onTap: () => c.playList(c.recentlyAdded, c.recentlyAdded.indexOf(t), from: 'Recently added'),
                  onPlay: () => c.playList(c.recentlyAdded, c.recentlyAdded.indexOf(t), from: 'Recently added'),
                ),
            ], onShowAll: () => shell.openCollection(c.allSongs)),
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

/// Shown on Home while there are no files yet: a small invitation, not a wall.
class _AddYourMusic extends StatelessWidget {
  const _AddYourMusic();

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.elevated, borderRadius: BorderRadius.circular(8)),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Add music from this device to play it offline.',
              style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
            ),
            OutlinedButton.icon(
              onPressed: shell.addFiles,
              icon: const Icon(Icons.audio_file_outlined),
              label: const Text('Add songs'),
            ),
            if (shell.addFolder != null)
              OutlinedButton.icon(
                onPressed: shell.addFolder,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Add a folder'),
              ),
          ],
        ),
      ),
    );
  }
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
        color: _hover ? AppColors.textPrimary.withValues(alpha: 0.16) : AppColors.tile,
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
      // Over the whole window, so a click anywhere (sidebar included) closes it.
      useRootNavigator: true,
      tooltip: 'Add music',
      icon: const Icon(Icons.add_rounded),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: shell.addFiles,
          child: const MenuRow(leading: Icon(Icons.audio_file_outlined), title: Text('Add songs')),
        ),
        PopupMenuItem(
          value: shell.importFromYoutube,
          child: const MenuRow(leading: Icon(Icons.add_link_rounded), title: Text('Import from YouTube')),
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
              Icon(Icons.library_music_outlined, size: 56, color: AppColors.textSecondary),
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
                      backgroundColor: AppColors.inverse,
                      foregroundColor: AppColors.onInverse,
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
                      side: BorderSide(color: AppColors.textMuted),
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
                        side: BorderSide(color: AppColors.textMuted),
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
