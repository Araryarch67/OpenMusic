import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../../services/player_controller.dart';
import '../../services/youtube_music_account.dart';
import '../../services/desktop_login.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/shelf.dart';
import 'collection_page.dart';
import 'home_page.dart';
import 'youtube_music_login_page.dart';
import '../widgets/smooth_scroll.dart';
import '../navigation.dart';
import '../ytmusic_edit.dart';
import '../../services/ytmusic_web.dart';

/// Home when the source is YouTube Music: public home, explore and charts
/// shelves for everyone; liked music, recent plays and playlists on top once
/// signed in. Everything streams on demand.
class YoutubeMusicHome extends StatelessWidget {
  const YoutubeMusicHome({super.key});

  @override
  Widget build(BuildContext context) {
    final account = PlayerScope.read(context).ytMusic;
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => account.isSignedIn ? const _LibraryHome() : const _DiscoverHome(),
    );
  }
}

/// The one sign-in: Google's own page, in a window on Linux (WebKitGTK helper)
/// and inside the app everywhere else.
Future<void> signInToYoutubeMusic(BuildContext context) async {
  final account = PlayerScope.read(context).ytMusic;
  if (DesktopLogin.supported) {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await account.signInWithWindow();
    if (!ok && account.error != null) messenger.showSnackBar(SnackBar(content: Text(account.error!)));
  } else if (YoutubeMusicAccount.canSignInInWindow) {
    ShellScope.of(context).open(const YoutubeMusicLoginPage());
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Signing in needs WebKitGTK (webkit2gtk-4.1). Install it and restart OpenMusic.')),
    );
  }
}

Collection likedCollection(List<Track> liked) =>
    Collection(kind: CollectionKind.remote, title: 'Liked music', subtitle: 'YouTube Music', tracks: liked);

/// Opens a library playlist or a public album / playlist in the current tab.
void openRemotePlaylist(BuildContext context, RemotePlaylist p) {
  final account = PlayerScope.read(context).ytMusic;
  // Library playlists open editable when they're the user's own.
  if (p.browseId == null && account.canEdit) {
    ShellScope.of(context).open(location: Locations.remotePlaylist(p.id), LibraryPlaylistPage(playlist: p));
    return;
  }
  final artistId = p.browseId?.startsWith('UC') ?? false ? p.browseId : null;
  ShellScope.of(context).open(
    location: Locations.remotePlaylist(p.id),
    RemoteCollectionPage(
      title: p.title,
      actions: [if (artistId != null) FollowButton(artistId: artistId, name: p.title)],
      load: () async => Collection(
        kind: CollectionKind.remote,
        title: p.title,
        subtitle: artistId != null ? 'Artist' : p.subtitle ?? 'YouTube Music',
        tracks: await account.collectionTracks(p),
      ),
    ),
  );
}

/// Placeholder track used only to show a playlist's cover image.
Track playlistCover(RemotePlaylist p) =>
    Track.youtube(videoId: 'playlist-${p.id}', title: p.title, artist: '', artworkUrl: p.thumbnailUrl);

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 0, pad, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text(title, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8))],
      ),
    );
  }
}

/// Readable column width for forms and prose on very wide windows.
class _Narrow extends StatelessWidget {
  const _Narrow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pad = ShellScope.of(context).compact ? 16.0 : 24.0;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: child,
        ),
      ),
    );
  }
}

// ── Discover (no sign-in needed) ───────────────────────────────────────────

class _DiscoverHome extends StatelessWidget {
  const _DiscoverHome();

  @override
  Widget build(BuildContext context) {
    final account = PlayerScope.read(context).ytMusic;
    final text = Theme.of(context).textTheme;
    final shell = ShellScope.of(context);
    final pad = shell.compact ? 16.0 : 24.0;
    return PageScaffold(
      title: 'YouTube Music',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: () => account.discover(refresh: true),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      slivers: [
        const SliverToBoxAdapter(child: _Header('YouTube Music')),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              decoration: BoxDecoration(color: AppColors.elevated, borderRadius: BorderRadius.circular(8)),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  Text(
                    'Sign in to add your liked music, playlists and history.',
                    style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                    onPressed: account.connecting ? null : () => signInToYoutubeMusic(context),
                    icon: const Icon(Icons.login_rounded),
                    label: Text(account.connecting ? 'Signing in…' : 'Sign in with Google'),
                  ),
                ],
              ),
            ),
          ),
        ),
        const DiscoverShelves(),
      ],
    );
  }
}

/// "Sign in with Google" strip for people not signed in to YouTube Music yet.
class SignInBanner extends StatelessWidget {
  const SignInBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final account = PlayerScope.of(context).ytMusic;
    final text = Theme.of(context).textTheme;
    final pad = ShellScope.of(context).compact ? 16.0 : 24.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(color: AppColors.elevated, borderRadius: BorderRadius.circular(8)),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text(
              'Sign in to YouTube Music to add your liked songs, playlists and history.',
              style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: account.connecting ? null : () => signInToYoutubeMusic(context),
              icon: const Icon(Icons.login_rounded),
              label: Text(account.connecting ? 'Signing in…' : 'Sign in with Google'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home, Explore and Charts shelves, as one sliver.
class DiscoverShelves extends StatelessWidget {
  const DiscoverShelves({super.key});

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    final text = Theme.of(context).textTheme;
    return FutureBuilder<List<RemoteShelf>>(
      future: c.ytMusic.discover(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
            ),
          );
        }
        if (snap.hasError) {
          return SliverToBoxAdapter(
            child: _Narrow(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Couldn\'t load YouTube Music: ${snap.error}',
                      style: text.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.error),
                    ),
                    const SizedBox(height: 8),
                    TextButton(onPressed: () => c.ytMusic.discover(refresh: true), child: const Text('Try again')),
                  ],
                ),
              ),
            ),
          );
        }
        return SliverList.list(
          children: [
            for (final (si, shelf) in snap.data!.indexed)
              FadeIn(
                delay: Duration(milliseconds: 70 * (si < 5 ? si : 5)),
                child: Shelf(
                  title: shelf.title,
                  cards: [
                    for (final (i, t) in shelf.tracks.indexed)
                      MediaCard(
                        track: t,
                        title: t.title,
                        subtitle: t.artist,
                        online: !PlayerScope.read(context).isOffline(t),
                        onTap: () => c.playList(shelf.tracks, i, from: shelf.title),
                        onPlay: () => c.playList(shelf.tracks, i, from: shelf.title),
                      ),
                    for (final p in shelf.collections)
                      MediaCard(
                        track: playlistCover(p),
                        title: p.title,
                        subtitle: p.subtitle ?? 'Playlist',
                        online: true,
                        onTap: () => openRemotePlaylist(context, p),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

// ── Signed-in home ──────────────────────────────────────────────────────────

class _LibraryHome extends StatelessWidget {
  const _LibraryHome();

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    final account = c.ytMusic;
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;

    return FutureBuilder<YoutubeMusicLibrary>(
      future: account.library(),
      builder: (context, snap) {
        final lib = snap.data;
        final liked = lib?.liked ?? const <Track>[];
        final likedCol = likedCollection(liked);
        return PageScaffold(
          title: 'YouTube Music',
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: () {
                account.library(refresh: true);
                account.discover(refresh: true);
              },
              icon: const Icon(Icons.refresh_rounded),
            ),
            PopupMenuButton<VoidCallback>(
              // Over the whole window, so a click anywhere (sidebar included) closes it.
              useRootNavigator: true,
              tooltip: 'Account',
              icon: const Icon(Icons.account_circle_outlined),
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  enabled: false,
                  child: Text(
                    [
                      account.accountName ?? 'Signed in',
                      if (account.browser != null) 'via ${account.browser}',
                      if (account.usesWebSession) 'via the app',
                    ].join(' · '),
                    style: text.bodyMedium,
                  ),
                ),
                PopupMenuItem(
                  value: account.signOut,
                  child: const ListTile(leading: Icon(Icons.logout_rounded), title: Text('Disconnect')),
                ),
              ],
            ),
          ],
          slivers: [
            const SliverToBoxAdapter(child: _Header('YouTube Music')),
            if (snap.connectionState != ConnectionState.done)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
                ),
              )
            else if (snap.hasError)
              SliverToBoxAdapter(
                child: _Narrow(
                  child: Text(
                    'Couldn\'t load your library: ${snap.error}',
                    style: text.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              )
            else ...[
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: pad),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: shell.compact ? 260 : 360,
                    mainAxisExtent: shell.compact ? 56 : 64,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: 1 + lib!.playlists.take(shell.compact ? 5 : 7).length,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return QuickTile(
                        title: 'Liked music',
                        leading: CoverMosaic(tracks: liked, radius: 0),
                        onTap: () => shell.openCollection(likedCol),
                        onPlay: liked.isEmpty ? null : () => c.playCollection(likedCol),
                      );
                    }
                    final p = lib.playlists[i - 1];
                    return QuickTile(
                      title: p.title,
                      leading: Artwork(track: playlistCover(p), radius: 0),
                      onTap: () => openRemotePlaylist(context, p),
                    );
                  },
                ),
              ),
              if (lib.recent.isNotEmpty)
                SliverToBoxAdapter(
                  child: Shelf(
                    title: 'Recently played',
                    cards: [
                      for (final (i, t) in lib.recent.indexed)
                        MediaCard(
                          track: t,
                          title: t.title,
                          subtitle: t.artist,
                          online: !PlayerScope.read(context).isOffline(t),
                          onTap: () => c.playList(lib.recent, i, from: 'Recently played'),
                          onPlay: () => c.playList(lib.recent, i, from: 'Recently played'),
                        ),
                    ],
                  ),
                ),
              if (liked.isNotEmpty)
                SliverToBoxAdapter(
                  child: Shelf(
                    title: 'Liked music',
                    onShowAll: () => shell.openCollection(likedCol),
                    cards: [
                      for (final (i, t) in liked.take(30).indexed)
                        MediaCard(
                          track: t,
                          title: t.title,
                          subtitle: t.artist,
                          online: !PlayerScope.read(context).isOffline(t),
                          onTap: () => c.playCollection(likedCol, index: i),
                          onPlay: () => c.playCollection(likedCol, index: i),
                        ),
                    ],
                  ),
                ),
              if (lib.playlists.isNotEmpty)
                SliverToBoxAdapter(
                  child: Shelf(
                    title: 'Your playlists',
                    cards: [
                      for (final p in lib.playlists)
                        MediaCard(
                          track: playlistCover(p),
                          title: p.title,
                          subtitle: p.count == 0 ? 'Playlist' : '${p.count} songs',
                          onTap: () => openRemotePlaylist(context, p),
                        ),
                    ],
                  ),
                ),
              if (lib.artists.isNotEmpty)
                SliverToBoxAdapter(
                  child: Shelf(
                    title: 'Artists you follow',
                    cards: [
                      for (final a in lib.artists)
                        MediaCard(
                          track: playlistCover(a),
                          title: a.title,
                          subtitle: a.subtitle ?? 'Artist',
                          circle: true,
                          onTap: () => openRemotePlaylist(context, a),
                        ),
                    ],
                  ),
                ),
              const DiscoverShelves(),
            ],
          ],
        );
      },
    );
  }
}

/// Loads a remote playlist, then shows it like any other collection.
class RemoteCollectionPage extends StatefulWidget {
  const RemoteCollectionPage({super.key, required this.title, required this.load, this.actions = const []});

  final String title;
  final Future<Collection> Function() load;

  /// Extra buttons next to Play / Shuffle (Follow on artist pages).
  final List<Widget> actions;

  @override
  State<RemoteCollectionPage> createState() => _RemoteCollectionPageState();
}

class _RemoteCollectionPageState extends State<RemoteCollectionPage> {
  late final Future<Collection> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _future,
      builder: (context, snap) {
        if (snap.hasData) return CollectionPage(collection: snap.data!, actions: widget.actions);
        return PageScaffold(
          title: widget.title,
          slivers: [
            SliverToBoxAdapter(child: _Header(widget.title)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Center(
                  child: snap.hasError
                      ? Text('Couldn\'t load this playlist: ${snap.error}')
                      : const CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One of the library's playlists. If the account owns it, it can be renamed,
/// made public or private, deleted, and songs can be removed from it.
class LibraryPlaylistPage extends StatefulWidget {
  const LibraryPlaylistPage({super.key, required this.playlist});

  final RemotePlaylist playlist;

  @override
  State<LibraryPlaylistPage> createState() => _LibraryPlaylistPageState();
}

class _LibraryPlaylistPageState extends State<LibraryPlaylistPage> {
  late String _title = widget.playlist.title;
  late Future<RemotePlaylistDetails> _details = _load();
  RemotePlaylistDetails? _shown;

  Future<RemotePlaylistDetails> _load() => PlayerScope.read(context).ytMusic.playlistDetails(widget.playlist.id);

  void _reload() => setState(() => _details = _load());

  void _removed(Track t) {
    final d = _shown;
    if (d == null) return;
    setState(() {
      _shown = RemotePlaylistDetails(
        tracks: [
          for (final x in d.tracks)
            if (x.id != t.id) x,
        ],
        owned: d.owned,
        privacy: d.privacy,
        rowIds: {...d.rowIds}..remove(t.id),
      );
      _details = Future.value(_shown!);
    });
  }

  Future<void> _rename() async {
    final account = PlayerScope.read(context).ytMusic;
    final messenger = ScaffoldMessenger.of(context);
    final answer = await askPlaylistName(context, initialTitle: _title, askPrivacy: false);
    if (answer == null) return;
    try {
      await account.renamePlaylist(widget.playlist.id, answer.title);
      setState(() => _title = answer.title);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _setPrivacy(PlaylistPrivacy privacy) async {
    final account = PlayerScope.read(context).ytMusic;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await account.setPlaylistPrivacy(widget.playlist.id, privacy);
      messenger.showSnackBar(SnackBar(content: Text('Playlist is now ${privacy.label.toLowerCase()}')));
      _reload();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete() async {
    final account = PlayerScope.read(context).ytMusic;
    final messenger = ScaffoldMessenger.of(context);
    final history = ShellScope.of(context).history;
    final navigator = Navigator.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text('"$_title" will be deleted from your YouTube Music library. This can\'t be undone.'),
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
    try {
      await account.deletePlaylist(widget.playlist.id);
      messenger.showSnackBar(SnackBar(content: Text('Deleted "$_title"')));
      history != null ? history.back() : navigator.maybePop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RemotePlaylistDetails>(
      future: _details,
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) {
          return PageScaffold(
            title: _title,
            slivers: [
              SliverToBoxAdapter(child: _Header(_title)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: Center(
                    child: snap.hasError
                        ? Column(
                            children: [
                              Text('Couldn\'t load this playlist: ${snap.error}'),
                              TextButton(onPressed: _reload, child: const Text('Try again')),
                            ],
                          )
                        : const CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              ),
            ],
          );
        }
        _shown = d;
        final collection = Collection(
          kind: CollectionKind.remote,
          title: _title,
          subtitle: [if (d.privacy != null) d.privacy!.label, 'YouTube Music'].join(' · '),
          tracks: d.tracks,
        );
        return PlaylistEditScope(
          canRemove: (t) => d.owned && d.rowIds.containsKey(t.id),
          remove: (context, t) async {
            final row = d.rowIds[t.id];
            if (row != null && await removeFromRemotePlaylist(context, widget.playlist.id, t, row)) _removed(t);
          },
          child: CollectionPage(
            collection: collection,
            actions: [
              if (d.owned)
                PopupMenuButton<VoidCallback>(
                  // Over the whole window, so a click anywhere (sidebar included) closes it.
                  useRootNavigator: true,
                  tooltip: 'Edit playlist',
                  icon: const Icon(Icons.more_horiz_rounded, size: 30),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _rename,
                      child: const ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename')),
                    ),
                    for (final p in PlaylistPrivacy.values)
                      if (p != d.privacy)
                        PopupMenuItem(
                          value: () => _setPrivacy(p),
                          child: ListTile(
                            leading: Icon(switch (p) {
                              PlaylistPrivacy.public => Icons.public_rounded,
                              PlaylistPrivacy.unlisted => Icons.link_rounded,
                              PlaylistPrivacy.private => Icons.lock_outline_rounded,
                            }),
                            title: Text('Make ${p.label.toLowerCase()}'),
                          ),
                        ),
                    PopupMenuItem(
                      value: _delete,
                      child: const ListTile(
                        leading: Icon(Icons.delete_outline_rounded),
                        title: Text('Delete playlist'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Sidebar / Library-tab list for the YouTube Music source.
class YoutubeMusicLibraryList extends StatelessWidget {
  const YoutubeMusicLibraryList({super.key, required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final account = c.ytMusic;
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    if (!account.isSignedIn) {
      return collapsed
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sign in to see your liked music and playlists here.',
                    style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                    onPressed: account.connecting ? null : () => signInToYoutubeMusic(context),
                    child: const Text('Sign in with Google'),
                  ),
                ],
              ),
            );
    }
    return FutureBuilder<YoutubeMusicLibrary>(
      future: account.library(),
      builder: (context, snap) {
        final lib = snap.data;
        if (lib == null) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final liked = likedCollection(lib.liked);
        Widget row({
          required Widget art,
          required String title,
          required String subtitle,
          required String location,
          required VoidCallback onTap,
        }) {
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
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          );
          final highlighted = SelectedHighlight(history: shell.history, location: location, child: tile);
          return collapsed ? Tooltip(message: title, child: highlighted) : highlighted;
        }

        return SmoothScroll(
          builder: (context, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            children: [
              if (account.canEdit)
                row(
                  art: const SizedBox.square(
                    dimension: 48,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: AppColors.hover),
                      child: Icon(Icons.add_rounded, color: AppColors.textPrimary),
                    ),
                  ),
                  title: 'New playlist',
                  subtitle: 'Create one in YouTube Music',
                  location: '',
                  onTap: () => createPlaylist(context),
                ),
              row(
                art: CoverMosaic(tracks: lib.liked, size: 48),
                title: 'Liked music',
                subtitle: 'Playlist • ${lib.liked.length} songs',
                location: Locations.collection(liked),
                onTap: () => shell.openCollection(liked),
              ),
              for (final p in lib.playlists)
                row(
                  art: Artwork(track: playlistCover(p), size: 48),
                  title: p.title,
                  subtitle: p.count == 0 ? 'Playlist' : 'Playlist • ${p.count} songs',
                  location: Locations.remotePlaylist(p.id),
                  onTap: () => openRemotePlaylist(context, p),
                ),
            ],
          ),
        );
      },
    );
  }
}
