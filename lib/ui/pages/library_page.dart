import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../../services/player_controller.dart';
import '../../services/youtube_music_account.dart';
import '../ytmusic_edit.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import 'settings_page.dart';
import 'youtube_music_page.dart';
import '../widgets/smooth_scroll.dart';
import '../navigation.dart';
import '../widgets/menus.dart';

enum LibraryFilter { playlists, albums, artists }

/// "Your Library": OpenMusic playlists, YouTube Music (liked songs and
/// playlists, marked with a cloud) and the files on this device, in one list.
/// Used both as the phone tab and (with [dense]) inside the desktop sidebar.
class LibraryList extends StatefulWidget {
  const LibraryList({super.key, this.dense = false, this.collapsed = false});

  final bool dense;

  /// Icon-only rail in the medium layout.
  final bool collapsed;

  @override
  State<LibraryList> createState() => _LibraryListState();
}

class _LibraryListState extends State<LibraryList> {
  LibraryFilter? _filter;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    return ListenableBuilder(listenable: c.ytMusic, builder: (context, _) => _build(context, c, c.ytMusic.libraryNow));
  }

  Widget _build(BuildContext context, PlayerController c, YoutubeMusicLibrary? online) {
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final account = c.ytMusic;
    bool show(LibraryFilter f) => _filter == null || _filter == f;

    final local = <Collection>[
      if (show(LibraryFilter.albums)) ...c.albums,
      if (show(LibraryFilter.artists)) ...c.artists,
    ];
    if (_filter == null) local.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    final rows = <Widget>[
      if (show(LibraryFilter.playlists)) ...[
        _SimpleRow(
          collapsed: widget.collapsed,
          art: const _IconArt(Icons.add_rounded),
          title: 'New playlist',
          subtitle: 'Mix your own songs and YouTube Music',
          onTap: () => createPlaylist(context),
        ),
        if (account.canEdit)
          _SimpleRow(
            collapsed: widget.collapsed,
            art: const _IconArt(Icons.group_add_outlined),
            title: 'Join a shared playlist',
            subtitle: 'Paste a link from a friend',
            onTap: () => joinSharedPlaylist(context),
          ),
        _SimpleRow(
          collapsed: widget.collapsed,
          art: const _IconArt(Icons.playlist_add_rounded),
          title: 'Import a playlist',
          subtitle: 'From Spotify, Apple Music or Deezer',
          onTap: () => importPlaylist(context),
        ),
        for (final p in c.playlists) _LibraryRow(collection: c.playlistCollection(p), collapsed: widget.collapsed),
        if (online != null) ...[
          if (online.liked.isNotEmpty)
            _LibraryRow(collection: likedCollection(online.liked), collapsed: widget.collapsed, online: true),
          for (final p in online.playlists)
            _SimpleRow(
              collapsed: widget.collapsed,
              art: Artwork(track: playlistCover(p), size: 48),
              title: p.title,
              subtitle: p.count == 0 ? 'Playlist • YouTube Music' : 'Playlist • YouTube Music • ${p.count} songs',
              online: true,
              location: Locations.remotePlaylist(p.id),
              onTap: () => openRemotePlaylist(context, p),
            ),
        ],
        if (c.library.isNotEmpty) _LibraryRow(collection: c.allSongs, collapsed: widget.collapsed),
        if (c.youtubeDownloads case final d?) _LibraryRow(collection: d, collapsed: widget.collapsed),
      ],
      for (final col in local) _LibraryRow(collection: col, collapsed: widget.collapsed),
      if (online != null && show(LibraryFilter.artists))
        for (final a in online.artists)
          _SimpleRow(
            collapsed: widget.collapsed,
            art: Artwork(track: playlistCover(a), size: 48, circle: true),
            title: a.title,
            subtitle: 'Artist • YouTube Music',
            online: true,
            location: Locations.remotePlaylist(a.id),
            onTap: () => openRemotePlaylist(context, a),
          ),
      if (!widget.collapsed && !account.isSignedIn && show(LibraryFilter.playlists))
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          child: _Prompt(
            title: 'Your YouTube Music',
            body: 'Sign in to see your liked songs and playlists here.',
            button: 'Sign in with Google',
            onPressed: account.connecting ? null : () => signInToYoutubeMusic(context),
          ),
        ),
      if (!widget.collapsed && c.library.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          child: _Prompt(
            title: 'Music on this device',
            body: 'Add audio files to play them offline.',
            button: 'Add songs',
            onPressed: shell.addFiles,
          ),
        ),
    ];

    final header = Padding(
      padding: EdgeInsets.fromLTRB(widget.collapsed ? 0 : 16, 12, widget.collapsed ? 0 : 8, 4),
      child: widget.collapsed
          ? IconButton(
              tooltip: 'New playlist',
              onPressed: () => createPlaylist(context),
              icon: const Icon(Icons.add_rounded),
            )
          : Row(
              children: [
                Icon(Icons.library_music_rounded, color: AppColors.textSecondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Your Library',
                    style: (widget.dense ? text.titleMedium : text.headlineSmall)?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: widget.dense ? AppColors.textSecondary : null,
                    ),
                  ),
                ),
                if (!widget.dense)
                  IconButton(
                    tooltip: 'Settings',
                    onPressed: () => shell.open(const SettingsPage()),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                PopupMenuButton<VoidCallback>(
                  // Over the whole window, so a click anywhere (sidebar included) closes it.
                  useRootNavigator: true,
                  tooltip: 'Add',
                  icon: const Icon(Icons.add_rounded),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: () => createPlaylist(context),
                      child: const MenuRow(leading: Icon(Icons.playlist_add_rounded), title: Text('New playlist')),
                    ),
                    PopupMenuItem(
                      value: shell.addFiles,
                      child: const MenuRow(leading: Icon(Icons.audio_file_outlined), title: Text('Add songs')),
                    ),
                    if (shell.addFolder != null)
                      PopupMenuItem(
                        value: shell.addFolder,
                        child: const MenuRow(leading: Icon(Icons.folder_open_rounded), title: Text('Add a folder')),
                      ),
                    PopupMenuItem(
                      value: shell.importFromYoutube,
                      child: const MenuRow(leading: Icon(Icons.add_link_rounded), title: Text('Import from YouTube')),
                    ),
                  ],
                ),
              ],
            ),
    );

    // Very short windows: drop the filter chips so the list keeps some room.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (!widget.collapsed && constraints.maxHeight >= 300)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in LibraryFilter.values)
                    FilterChip(
                      label: Text(switch (f) {
                        LibraryFilter.playlists => 'Playlists',
                        LibraryFilter.albums => 'Albums',
                        LibraryFilter.artists => 'Artists',
                      }),
                      selected: _filter == f,
                      onSelected: (on) => setState(() => _filter = on ? f : null),
                    ),
                ],
              ),
            ),
          Expanded(
            child: SmoothScroll(
              builder: (context, scroll) => ListView(
                controller: scroll,
                padding: EdgeInsets.fromLTRB(8, 0, 8, (widget.dense ? 8 : 16) + MediaQuery.paddingOf(context).bottom),
                children: rows,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IconArt extends StatelessWidget {
  const _IconArt(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: DecoratedBox(
      decoration: BoxDecoration(color: AppColors.hover, borderRadius: BorderRadius.circular(4)),
      child: Icon(icon, color: AppColors.textPrimary),
    ),
  );
}

/// A library entry that isn't a [Collection] (YouTube Music playlists, "New playlist").
class _SimpleRow extends StatelessWidget {
  const _SimpleRow({
    required this.collapsed,
    required this.art,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.location,
    this.online = false,
  });

  final bool collapsed;
  final Widget art;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? location;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final shell = ShellScope.of(context);
    final tile = InkWell(
      borderRadius: BorderRadius.circular(6),
      hoverColor: AppColors.tile,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: collapsed
            ? Center(child: art)
            : Row(
                children: [
                  art,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (online) ...[const SourceMark(online: true, size: 13), const SizedBox(width: 4)],
                            Expanded(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
    final highlighted = location == null
        ? tile
        : SelectedHighlight(history: shell.history, location: location!, child: tile);
    return collapsed ? Tooltip(message: title, child: highlighted) : highlighted;
  }
}

class _LibraryRow extends StatelessWidget {
  const _LibraryRow({required this.collection, required this.collapsed, this.online = false});

  final Collection collection;
  final bool collapsed;

  /// A YouTube Music collection (Liked music): marked with a cloud.
  final bool online;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final playingHere = c.isPlayingFrom(collection);
    final isArtist = collection.kind == CollectionKind.artist;
    final art = collection.kind == CollectionKind.allSongs
        ? CoverMosaic(tracks: collection.tracks, size: 48)
        : Artwork(track: collection.cover, size: 48, circle: isArtist);

    final tile = InkWell(
      borderRadius: BorderRadius.circular(6),
      hoverColor: AppColors.tile,
      onTap: () => shell.openCollection(collection),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: collapsed
            ? Center(child: art)
            : Row(
                children: [
                  art,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          collection.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: playingHere ? AppColors.accent : AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (online) ...[const SourceMark(online: true, size: 13), const SizedBox(width: 4)],
                            Expanded(
                              child: Text(
                                switch (collection.kind) {
                                  CollectionKind.allSongs ||
                                  CollectionKind.youtube ||
                                  CollectionKind.remote => 'Playlist • ${collection.subtitle}',
                                  CollectionKind.playlist => 'Playlist • OpenMusic • ${collection.subtitle}',
                                  CollectionKind.album => 'Album • ${collection.subtitle}',
                                  CollectionKind.artist => 'Artist',
                                },
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (playingHere)
                    Icon(
                      c.isPlaying ? Icons.volume_up_rounded : Icons.volume_mute_rounded,
                      color: AppColors.accent,
                      size: 18,
                    ),
                ],
              ),
      ),
    );
    final highlighted = SelectedHighlight(
      history: shell.history,
      location: Locations.collection(collection),
      child: tile,
    );
    return collapsed ? Tooltip(message: collection.title, child: highlighted) : highlighted;
  }
}

class _Prompt extends StatelessWidget {
  const _Prompt({required this.title, required this.body, required this.button, required this.onPressed});

  final String title;
  final String body;
  final String button;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.elevated, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(body, style: text.bodySmall),
          const SizedBox(height: 14),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.inverse, foregroundColor: AppColors.onInverse),
            onPressed: onPressed,
            child: Text(button),
          ),
        ],
      ),
    );
  }
}

/// Phone tab wrapper around [LibraryList].
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      child: SafeArea(bottom: false, child: const LibraryList()),
    );
  }
}
