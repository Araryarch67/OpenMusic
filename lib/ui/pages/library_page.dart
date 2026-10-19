import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import 'home_page.dart';
import 'settings_page.dart';
import 'youtube_music_page.dart';
import '../widgets/source_switch.dart';
import '../widgets/smooth_scroll.dart';

enum LibraryFilter { albums, artists }

/// "Your Library": pinned All Songs plus albums / artists. Used both as the
/// phone tab and (with [dense]) inside the desktop sidebar.
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
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final items = <Collection>[
      if (_filter != LibraryFilter.artists) ...c.albums,
      if (_filter != LibraryFilter.albums) ...c.artists,
    ];
    if (_filter == null) items.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final all = c.allSongs;
    final rows = [all, ?c.youtubeDownloads, ...items];

    final header = Padding(
      padding: EdgeInsets.fromLTRB(widget.collapsed ? 0 : 16, 12, widget.collapsed ? 0 : 8, 4),
      child: widget.collapsed
          ? IconButton(tooltip: 'Add music', onPressed: shell.addFiles, icon: const Icon(Icons.add_rounded))
          : Row(
              children: [
                const Icon(Icons.library_music_rounded, color: AppColors.textSecondary),
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
                  tooltip: 'Add music',
                  icon: const Icon(Icons.add_rounded),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: shell.addFiles,
                      child: const ListTile(leading: Icon(Icons.audio_file_outlined), title: Text('Add songs')),
                    ),
                    if (shell.addFolder != null)
                      PopupMenuItem(
                        value: shell.addFolder,
                        child: const ListTile(leading: Icon(Icons.folder_open_rounded), title: Text('Add a folder')),
                      ),
                    PopupMenuItem(
                      value: shell.importFromYoutube,
                      child: const ListTile(leading: Icon(Icons.add_link_rounded), title: Text('Import from YouTube')),
                    ),
                  ],
                ),
              ],
            ),
    );

    if (c.library.isEmpty && !widget.dense && c.source == MusicSource.local) {
      return Column(
        children: [
          header,
          const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 8), child: SourceSwitch()),
          const Expanded(child: SingleChildScrollView(child: EmptyLibrary())),
        ],
      );
    }

    // Very short windows: drop the filter chips so the list keeps some room.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (!widget.collapsed &&
              c.library.isNotEmpty &&
              c.source == MusicSource.local &&
              constraints.maxHeight >= 300)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final f in LibraryFilter.values)
                    FilterChip(
                      label: Text(f == LibraryFilter.albums ? 'Albums' : 'Artists'),
                      selected: _filter == f,
                      onSelected: (on) => setState(() => _filter = on ? f : null),
                    ),
                ],
              ),
            ),
          if (!widget.dense) const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 8), child: SourceSwitch()),
          if (c.source == MusicSource.youtubeMusic)
            Expanded(child: YoutubeMusicLibraryList(collapsed: widget.collapsed))
          else ...[
            if (c.library.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: widget.collapsed ? const SizedBox.shrink() : _SidebarPrompt(onAdd: shell.addFiles),
              )
            else
              Expanded(
                child: SmoothScroll(
                  builder: (context, scroll) => ListView.builder(
                    controller: scroll,
                    padding: EdgeInsets.fromLTRB(8, 0, 8, widget.dense ? 8 : 16),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _LibraryRow(collection: rows[i], collapsed: widget.collapsed),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _LibraryRow extends StatelessWidget {
  const _LibraryRow({required this.collection, required this.collapsed});

  final Collection collection;
  final bool collapsed;

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
                        Text(
                          switch (collection.kind) {
                            CollectionKind.allSongs ||
                            CollectionKind.youtube ||
                            CollectionKind.remote => 'Playlist • ${collection.subtitle}',
                            CollectionKind.album => 'Album • ${collection.subtitle}',
                            CollectionKind.artist => 'Artist',
                          },
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
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
    return collapsed ? Tooltip(message: collection.title, child: tile) : tile;
  }
}

class _SidebarPrompt extends StatelessWidget {
  const _SidebarPrompt({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.elevated, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Add your first songs', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('Pick audio files from this device.', style: text.bodySmall),
          const SizedBox(height: 14),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
            onPressed: onAdd,
            child: const Text('Add songs'),
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
