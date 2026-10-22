import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/shelf.dart';
import '../widgets/track_row.dart';
import '../ytmusic_edit.dart';
import '../widgets/menus.dart';

/// Album / artist / "All Songs" page with a colour-washed header.
class CollectionPage extends StatelessWidget {
  const CollectionPage({super.key, required this.collection, this.actions = const []});

  final Collection collection;

  /// Extra buttons next to Play / Shuffle (e.g. editing one of your playlists).
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    // Liked music changes with every like, wherever in the app it's made.
    if (collection.id == likedMusicId) {
      return ListenableBuilder(listenable: c.ytMusic, builder: (context, _) => _build(context, c));
    }
    return _build(context, c);
  }

  Widget _build(BuildContext context, PlayerController c) {
    final shell = ShellScope.of(context);
    // Re-resolve so tag scans / removals show up while the page is open.
    final live =
        switch (collection.kind) {
          CollectionKind.allSongs => c.allSongs,
          CollectionKind.youtube => c.youtubeDownloads,
          CollectionKind.remote => switch (c.ytMusic.libraryNow?.liked) {
            final liked? when collection.id == likedMusicId => Collection(
              kind: collection.kind,
              id: likedMusicId,
              title: collection.title,
              subtitle: collection.subtitle,
              tracks: liked,
            ),
            _ => null,
          },
          CollectionKind.playlist => c.playlistById(collection.id),
          CollectionKind.artist => c.artistNamed(collection.title),
          CollectionKind.album => c.albums.where((a) => a.title == collection.title).firstOrNull,
        } ??
        collection;
    final tracks = live.tracks;
    final playingHere = c.isPlayingFrom(live);
    final isArtist = live.kind == CollectionKind.artist;
    final isAll = live.kind == CollectionKind.allSongs;
    final multiDisc = live.kind == CollectionKind.album && tracks.map((t) => t.discNumber ?? 1).toSet().length > 1;
    final text = Theme.of(context).textTheme;
    final playlistId = live.kind == CollectionKind.playlist ? live.id : null;
    final actions = [...this.actions, if (playlistId != null) _PlaylistMenu(id: playlistId, name: live.title)];

    final page = AccentBuilder(
      track: live.cover,
      builder: (context, accent) {
        final headerColor = accent;
        return PageScaffold(
          gradientColor: headerColor,
          title: live.title,
          slivers: [
            SliverToBoxAdapter(
              child: _Header(collection: live, accent: headerColor),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(shell.compact ? 16 : 24, 16, 24, 8),
                child: Row(
                  children: [
                    PlayButton(
                      size: 56,
                      color: AppColors.accent,
                      iconColor: AppColors.onAccent,
                      playing: playingHere && c.isPlaying,
                      onPressed: tracks.isEmpty
                          ? null
                          : playingHere
                          ? c.togglePlay
                          : () => c.playCollection(live),
                    ),
                    const SizedBox(width: 16),
                    // Lit while this collection plays shuffled; there it toggles shuffle.
                    ModeButton(
                      tooltip: playingHere ? (c.shuffle ? 'Disable shuffle' : 'Enable shuffle') : 'Shuffle play',
                      active: playingHere && c.shuffle,
                      size: 30,
                      icon: Icons.shuffle_rounded,
                      onPressed: tracks.isEmpty
                          ? null
                          : playingHere
                          ? c.toggleShuffle
                          : () => c.playCollection(live, shuffled: true),
                    ),
                    ...actions,
                    if (isAll) ...[
                      const Spacer(),
                      IconButton(
                        tooltip: 'Add files',
                        onPressed: shell.addFiles,
                        icon: const Icon(Icons.add_circle_outline_rounded),
                      ),
                    ],
                    if (live.kind == CollectionKind.remote && tracks.isNotEmpty) ...[
                      const Spacer(),
                      IconButton(
                        tooltip: 'Download all for offline',
                        onPressed: () {
                          final n = c.youtube.enqueueTracks(tracks);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(n == 0 ? 'Already downloaded' : 'Downloading $n songs…')),
                          );
                        },
                        icon: const Icon(Icons.download_for_offline_outlined),
                      ),
                    ],
                    if (live.kind == CollectionKind.youtube) ...[
                      const Spacer(),
                      IconButton(
                        tooltip: 'Import from YouTube',
                        onPressed: shell.importFromYoutube,
                        icon: const Icon(Icons.add_link_rounded),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (!shell.compact) SliverToBoxAdapter(child: _ColumnHeader(showAlbum: live.kind != CollectionKind.album)),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: shell.compact ? 12 : 16),
              sliver: SliverList.list(
                children: [
                  for (var i = 0; i < tracks.length; i++) ...[
                    // Multi-disc albums: a "Disc 2" heading where each disc starts.
                    if (multiDisc && (i == 0 || tracks[i].discNumber != tracks[i - 1].discNumber))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Row(
                          children: [
                            Icon(Icons.album_outlined, size: 18, color: AppColors.textSecondary),
                            const SizedBox(width: 12),
                            Text(
                              'Disc ${tracks[i].discNumber ?? 1}',
                              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                    TrackRow(
                      track: tracks[i],
                      index: multiDisc ? (tracks[i].trackNumber ?? i + 1) : i + 1,
                      showArtwork: live.kind != CollectionKind.album,
                      showAlbum: live.kind != CollectionKind.album,
                      onTap: () => c.playCollection(live, index: i),
                    ),
                  ],
                ],
              ),
            ),
            if (isArtist) ..._artistAlbums(context, c, live),
          ],
        );
      },
    );
    if (playlistId == null) return page;
    // An OpenMusic playlist: every song in it can be taken out.
    return PlaylistEditScope(
      canRemove: (t) => tracks.any((x) => x.id == t.id),
      remove: (context, t) async {
        c.removeFromPlaylist(playlistId, t);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed from ${live.title}'),
            action: SnackBarAction(label: 'Undo', onPressed: () => c.addToPlaylist(playlistId, [t])),
          ),
        );
      },
      child: page,
    );
  }

  List<Widget> _artistAlbums(BuildContext context, PlayerController c, Collection artist) {
    final albums = c.albums.where((a) => a.subtitle == artist.title).toList();
    if (albums.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: Shelf(
          title: 'Albums',
          cards: [
            for (final album in albums)
              MediaCard(
                track: album.cover,
                title: album.title,
                subtitle: 'Album',
                onTap: () => ShellScope.of(context).openCollection(album),
                onPlay: () => c.playCollection(album),
              ),
          ],
        ),
      ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.collection, required this.accent});

  final Collection collection;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final isArtist = collection.kind == CollectionKind.artist;
    final isAll = collection.kind == CollectionKind.allSongs;
    final total = formatTotal(collection.tracks);
    final count = '${collection.tracks.length} ${collection.tracks.length == 1 ? 'song' : 'songs'}';
    final meta = [
      if (collection.kind == CollectionKind.album) collection.subtitle,
      count,
      if (total.isNotEmpty) total,
    ].join(' • ');

    final art = Container(
      decoration: BoxDecoration(
        shape: isArtist ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isArtist ? null : BorderRadius.circular(6),
        boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 48, offset: Offset(0, 4))],
      ),
      child: isAll
          ? CoverMosaic(tracks: collection.tracks, size: shell.compact ? 200 : 220, radius: 6)
          : Artwork(track: collection.cover, size: shell.compact ? 200 : 220, radius: 6, circle: isArtist),
    );

    final titleSize = shell.compact
        ? 30.0
        : collection.title.length > 24
        ? 40.0
        : 64.0;
    final info = Column(
      crossAxisAlignment: shell.compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!shell.compact) Text(collection.kind.label, style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          collection.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: shell.compact ? TextAlign.center : TextAlign.start,
          style: text.displaySmall?.copyWith(
            fontSize: titleSize,
            fontWeight: FontWeight.w900,
            letterSpacing: -1.5,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 12),
        Text(meta, style: text.bodyMedium?.copyWith(color: AppColors.textPrimary.withValues(alpha: 0.8))),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(shell.compact ? 16 : 24, shell.compact ? 8 : 32, 24, 8),
      child: shell.compact
          ? Column(children: [art, const SizedBox(height: 20), info])
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                art,
                const SizedBox(width: 24),
                Expanded(child: info),
              ],
            ),
    );
  }
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({required this.showAlbum});

  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 32,
                child: Center(child: Text('#', style: style)),
              ),
              const SizedBox(width: 12),
              Expanded(flex: 5, child: Text('Title', style: style)),
              if (showAlbum && shell.width > 900) ...[
                const SizedBox(width: 16),
                Expanded(flex: 4, child: Text('Album', style: style)),
              ],
              const SizedBox(
                width: 56,
                child: Align(alignment: Alignment.centerRight, child: Icon(Icons.schedule_rounded, size: 16)),
              ),
              const SizedBox(width: 40),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Rename / delete for an OpenMusic playlist.
class _PlaylistMenu extends StatelessWidget {
  const _PlaylistMenu({required this.id, required this.name});

  final String id;
  final String name;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    return PopupMenuButton<VoidCallback>(
      // Over the whole window, so a click anywhere (sidebar included) closes it.
      useRootNavigator: true,
      tooltip: 'Edit playlist',
      icon: const Icon(Icons.more_horiz_rounded, size: 30),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: () async {
            final answer = await askPlaylistName(context, initialTitle: name, askPrivacy: false);
            if (answer != null) c.renamePlaylist(id, answer.title);
          },
          child: const MenuRow(leading: Icon(Icons.edit_outlined), title: Text('Rename')),
        ),
        PopupMenuItem(
          value: () async {
            final history = ShellScope.of(context).history;
            final navigator = Navigator.of(context);
            final sure = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Delete playlist?'),
                content: Text('"$name" will be deleted. The songs stay in your library.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
            if (sure != true) return;
            c.deletePlaylist(id);
            history != null ? history.back() : navigator.maybePop();
          },
          child: const MenuRow(leading: Icon(Icons.delete_outline_rounded), title: Text('Delete playlist')),
        ),
      ],
    );
  }
}
