import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/track.dart';
import '../../services/player_controller.dart';
import '../../services/youtube_music_account.dart';
import '../../services/ytdlp.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/shelf.dart';
import '../widgets/source_switch.dart';
import 'collection_page.dart';
import 'home_page.dart';

/// Home when the source is YouTube Music: connect first, then liked music,
/// recent plays and playlists, all streamed on demand.
class YoutubeMusicHome extends StatelessWidget {
  const YoutubeMusicHome({super.key});

  @override
  Widget build(BuildContext context) {
    final account = PlayerScope.read(context).ytMusic;
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => account.isSignedIn ? const _LibraryHome() : const _ConnectView(),
    );
  }
}

Collection likedCollection(List<Track> liked) =>
    Collection(kind: CollectionKind.remote, title: 'Liked music', subtitle: 'YouTube Music', tracks: liked);

/// Opens a playlist from the signed-in account in the current tab.
void openRemotePlaylist(BuildContext context, RemotePlaylist p) {
  final account = PlayerScope.read(context).ytMusic;
  ShellScope.of(context).open(
    RemoteCollectionPage(
      title: p.title,
      load: () async => Collection(
        kind: CollectionKind.remote,
        title: p.title,
        subtitle: 'YouTube Music',
        tracks: await account.playlistTracks(p.id),
      ),
    ),
  );
}

/// Placeholder track used only to show a playlist's cover image.
Track playlistCover(RemotePlaylist p) =>
    Track.youtube(videoId: 'playlist-${p.id}', title: p.title, artist: '', artworkUrl: p.thumbnailUrl);

class _Header extends StatelessWidget {
  const _Header(this.title, {this.subtitle});

  final String title;
  final String? subtitle;

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
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: text.bodyLarge?.copyWith(color: AppColors.textSecondary)),
          ],
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

// ── Connect ─────────────────────────────────────────────────────────────────

class _ConnectView extends StatefulWidget {
  const _ConnectView();

  @override
  State<_ConnectView> createState() => _ConnectViewState();
}

class _ConnectViewState extends State<_ConnectView> {
  late final Future<List<String>> _installed = YtDlp.supported ? YtDlp.installedBrowsers() : Future.value(const []);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final account = PlayerScope.read(context).ytMusic;
    return PageScaffold(
      title: 'YouTube Music',
      slivers: [
        const SliverToBoxAdapter(
          child: _Header('Connect YouTube Music', subtitle: 'Stream your liked music, playlists and recent plays.'),
        ),
        SliverToBoxAdapter(
          child: _Narrow(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (YtDlp.supported) ...[
                  Text('Use your browser\'s login', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    'Sign in at music.youtube.com in your browser as usual, then pick that browser. '
                    'OpenMusic reads the session from the browser each time; it never stores your cookies or password.',
                    style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  FutureBuilder<List<String>>(
                    future: _installed,
                    builder: (context, snap) {
                      final installed = snap.data ?? const <String>[];
                      final others = YtDlp.browsers.where((b) => !installed.contains(b)).toList();
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final (i, b) in installed.indexed)
                            _BrowserButton(browser: b, primary: i == 0, busy: account.connecting),
                          PopupMenuButton<String>(
                            tooltip: 'Other browsers',
                            enabled: !account.connecting,
                            onSelected: account.connectBrowser,
                            itemBuilder: (_) => [
                              for (final b in others) PopupMenuItem(value: b, child: Text(_label(b))),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                              child: Text(
                                installed.isEmpty ? 'Choose browser…' : 'Other browser…',
                                style: text.labelLarge?.copyWith(color: AppColors.textSecondary),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () => launchUrl(Uri.parse('https://music.youtube.com')),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('Open music.youtube.com'),
                      ),
                      if (account.connecting)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 8),
                            Text('Checking your login…', style: text.bodySmall),
                          ],
                        ),
                    ],
                  ),
                ] else
                  Text(
                    'On phones, connect with a Google OAuth client below.',
                    style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                  ),
                if (account.error != null) ...[
                  const SizedBox(height: 12),
                  Text(account.error!, style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    initiallyExpanded: !YtDlp.supported || account.isSigningIn,
                    title: Text(
                      'Advanced: sign in with your own Google OAuth client',
                      style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      'Uses the official YouTube Data API. Liked music and playlists only.',
                      style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                    ),
                    childrenPadding: const EdgeInsets.only(bottom: 16),
                    children: const [_OAuthSection()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _label(String b) => switch (b) {
    'firefox' => 'Firefox',
    'chrome' => 'Chrome',
    'chromium' => 'Chromium',
    'brave' => 'Brave',
    'edge' => 'Edge',
    'vivaldi' => 'Vivaldi',
    'opera' => 'Opera',
    'safari' => 'Safari',
    _ => b,
  };
}

class _BrowserButton extends StatelessWidget {
  const _BrowserButton({required this.browser, required this.primary, required this.busy});

  final String browser;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final account = PlayerScope.read(context).ytMusic;
    final label = Text('Use ${_ConnectViewState._label(browser)}');
    final onPressed = busy ? null : () => account.connectBrowser(browser);
    return primary
        ? FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            ),
            onPressed: onPressed,
            child: label,
          )
        : OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: const BorderSide(color: AppColors.textMuted),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            ),
            onPressed: onPressed,
            child: label,
          );
  }
}

/// OAuth client fields, then the device-code sign-in.
class _OAuthSection extends StatefulWidget {
  const _OAuthSection();

  @override
  State<_OAuthSection> createState() => _OAuthSectionState();
}

class _OAuthSectionState extends State<_OAuthSection> {
  final _id = TextEditingController();
  final _secret = TextEditingController();

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final account = PlayerScope.read(context).ytMusic;
    final code = account.pendingCode;
    if (code != null) return _CodeCard(code: code, onCancel: account.cancelSignIn);
    if (account.hasOAuthClient) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: account.signIn,
              icon: const Icon(Icons.login_rounded),
              label: const Text('Sign in with Google'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
              onPressed: () => account.configure(clientId: '', clientSecret: ''),
              child: const Text('Change OAuth client'),
            ),
          ],
        ),
      );
    }
    const steps = [
      'Google Cloud Console → create a project.',
      'Enable "YouTube Data API v3".',
      'OAuth consent screen → External; add yourself as a test user.',
      'Credentials → OAuth client ID → "TVs and Limited Input devices".',
    ];
    InputDecoration field(String label) => InputDecoration(
      labelText: label,
      filled: true,
      fillColor: AppColors.hover,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, step) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('${i + 1}. $step', style: text.bodyMedium),
          ),
        TextButton.icon(
          onPressed: () => launchUrl(Uri.parse('https://console.cloud.google.com/apis/credentials')),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text('Open Google Cloud Console'),
        ),
        const SizedBox(height: 8),
        TextField(controller: _id, decoration: field('Client ID')),
        const SizedBox(height: 12),
        TextField(controller: _secret, obscureText: true, decoration: field('Client secret')),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: Listenable.merge([_id, _secret]),
          builder: (context, _) => FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
            onPressed: _id.text.trim().isEmpty || _secret.text.trim().isEmpty
                ? null
                : () => account.configure(clientId: _id.text, clientSecret: _secret.text),
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code, required this.onCancel});

  final DeviceCode code;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final url = Uri.parse(code.verificationUrl);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppColors.elevated, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Open ${url.host}${url.path} and enter this code:', style: text.bodyLarge),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: SelectableText(
              code.userCode,
              style: text.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 4),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code.userCode));
                  launchUrl(url);
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Copy code & open'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
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
              onPressed: () => account.library(refresh: true),
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
              child: Text(
                'Connect YouTube Music from Home to see your library here.',
                style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
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

        return ListView(
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
        );
      },
    );
  }
}
