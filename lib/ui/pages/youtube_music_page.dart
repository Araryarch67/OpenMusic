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
import '../widgets/source_switch.dart';
import 'collection_page.dart';
import 'home_page.dart';
import 'youtube_music_login_page.dart';
import '../widgets/smooth_scroll.dart';

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
  ShellScope.of(context).open(
    RemoteCollectionPage(
      title: p.title,
      load: () async => Collection(
        kind: CollectionKind.remote,
        title: p.title,
        subtitle: p.subtitle ?? 'YouTube Music',
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
        children: [
          if (shell.compact) ...[const SourceSwitch(), const SizedBox(height: 16)],
          Text(title, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8)),
        ],
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
        const _DiscoverShelves(),
      ],
    );
  }
}

/// Home, Explore and Charts shelves, as one sliver.
class _DiscoverShelves extends StatelessWidget {
  const _DiscoverShelves();

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
                        onTap: () => c.playList(shelf.tracks, i, from: shelf.title),
                        onPlay: () => c.playList(shelf.tracks, i, from: shelf.title),
                      ),
                    for (final p in shelf.collections)
                      MediaCard(
                        track: playlistCover(p),
                        title: p.title,
                        subtitle: p.subtitle ?? 'Playlist',
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
              const _DiscoverShelves(),
            ],
          ],
        );
      },
    );
  }
}

/// Loads a remote playlist, then shows it like any other collection.
class RemoteCollectionPage extends StatefulWidget {
  const RemoteCollectionPage({super.key, required this.title, required this.load});

  final String title;
  final Future<Collection> Function() load;

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
        if (snap.hasData) return CollectionPage(collection: snap.data!);
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
          return collapsed ? Tooltip(message: title, child: tile) : tile;
        }

        return SmoothScroll(
          builder: (context, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            children: [
              row(
                art: CoverMosaic(tracks: lib.liked, size: 48),
                title: 'Liked music',
                subtitle: 'Playlist • ${lib.liked.length} songs',
                onTap: () => shell.openCollection(liked),
              ),
              for (final p in lib.playlists)
                row(
                  art: Artwork(track: playlistCover(p), size: 48),
                  title: p.title,
                  subtitle: p.count == 0 ? 'Playlist' : 'Playlist • ${p.count} songs',
                  onTap: () => openRemotePlaylist(context, p),
                ),
            ],
          ),
        );
      },
    );
  }
}
