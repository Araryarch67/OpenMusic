import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/track.dart';
import '../services/appearance.dart';
import '../services/player_controller.dart';
import 'pages/collection_page.dart';
import 'pages/downloads_page.dart';
import 'pages/home_page.dart';
import 'pages/library_page.dart';
import 'pages/lyrics_page.dart';
import 'pages/queue_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'navigation.dart';
import 'player_panels.dart';
import 'shell_scope.dart';
import 'theme.dart';
import 'youtube_import.dart';
import '../services/youtube_importer.dart';
import 'widgets/smooth_scroll.dart';
import 'widgets/title_bar.dart';

enum _Tab { home, search, library }

/// Root layout.
///  * < 700px: bottom tabs + floating mini player, full-screen now playing.
///  * 700–1200px: collapsed library rail + content + player bar.
///  * ≥ 1200px: full library sidebar + content + now-playing side panel.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  _Tab _tab = _Tab.home;
  bool _sidePanel = true;
  final _searchFocus = FocusNode();

  /// The title bar's search box (desktop); the phone tab has its own.
  final _search = SearchInput();
  final _navigators = {for (final t in _Tab.values) t: GlobalKey<NavigatorState>()};

  NavigatorState? get _nav => _navigators[_tab]!.currentState;

  /// Desktop: one browser-style history for the content area.
  late final _history = DesktopHistory(routeBuilder: (page, location) => _route(page, location: location));

  StreamSubscription<String>? _errors;
  PlayerController? _player;
  bool _hasTrack = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = PlayerScope.identity(context);
    if (identical(c, _player)) return;
    _player?.removeListener(_followTrack);
    _player = c..addListener(_followTrack);
    _hasTrack = c.currentTrack != null;
    _errors?.cancel();
    _errors = c.errors.listen((message) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  /// All the shell itself needs from the player is whether a song is loaded
  /// (for the side panel). Rebuilding it on every change the player notifies
  /// rebuilt the whole window, several times a song; whatever shows what's
  /// playing listens on its own.
  void _followTrack() {
    final has = _player!.currentTrack != null;
    if (has != _hasTrack) setState(() => _hasTrack = has);
  }

  @override
  void dispose() {
    _player?.removeListener(_followTrack);
    _errors?.cancel();
    _searchFocus.dispose();
    _search.dispose();
    if (titleBarInShell.value) titleBarInShell.value = false;
    super.dispose();
  }

  /// Desktop: a new step in the one history. Phone: a page on the current tab.
  void _open(Widget page, {String? location}) {
    final where = location ?? _locationOf(page);
    if (!_compact) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _history.open(page, where));
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _nav?.push(_route(page, location: where)));
  }

  static String _locationOf(Widget page) => switch (page) {
    HomePage() => Locations.home,
    SearchPage() => Locations.search,
    SettingsPage() => Locations.settings,
    DownloadsPage() => Locations.downloads,
    LibraryPage() => Locations.library,
    CollectionPage(:final collection) => Locations.collection(collection),
    _ => page.runtimeType.toString(),
  };

  void _openSettings() {
    if (_history.location != Locations.settings) _open(const SettingsPage());
  }

  void _goHome() {
    if (_compact) return _selectTab(_Tab.home);
    if (_history.location != Locations.home) _history.open(const HomePage(), Locations.home);
  }

  void _goSearch() {
    if (_compact) return _selectTab(_Tab.search);
    _showSearchResults();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search.focus.requestFocus());
  }

  /// The search page, fed by the title bar's box (opened as soon as you type).
  void _showSearchResults() {
    if (_history.location == Locations.search) return;
    final typing = _search.focus.hasFocus;
    _history.open(SearchPage(input: _search), Locations.search);
    // The new page takes keyboard focus once it's built; the next keystrokes belong in the box.
    if (typing) WidgetsBinding.instance.addPostFrameCallback((_) => _search.focus.requestFocus());
  }

  /// Back / Forward, Home and search, in the desktop title bar.
  Widget _titleBar() => AppTitleBar(
    height: AppTitleBar.tallHeight,
    leading: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MoreMenu(onDownloads: () => _open(const DownloadsPage()), onSettings: _openSettings),
        const SizedBox(width: 4),
        HistoryButtons(history: _history),
      ],
    ),
    center: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Row(
        children: [
          ListenableBuilder(
            listenable: _history,
            builder: (context, _) {
              final home = _history.location == Locations.home;
              return IconButton.filled(
                tooltip: 'Home',
                onPressed: _goHome,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.tile,
                  hoverColor: AppColors.hover,
                  foregroundColor: home ? AppColors.textPrimary : AppColors.textSecondary,
                  fixedSize: const Size(48, 48),
                ),
                icon: Icon(home ? Icons.home_rounded : Icons.home_outlined, size: 26),
              );
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SearchBox(
              onBar: true,
              controller: _search.controller,
              focusNode: _search.focus,
              onChanged: (q) {
                if (q.trim().isNotEmpty) _showSearchResults();
              },
              onSubmitted: (q) {
                _showSearchResults();
                _search.submit(q);
              },
            ),
          ),
        ],
      ),
    ),
  );

  static Route<void> _route(Widget page, {String? location}) => PageRouteBuilder(
    // The page rides along so Forward can rebuild it after Back.
    settings: RouteSettings(name: location, arguments: page),
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, anim, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0.03, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );

  void _selectTab(_Tab tab) {
    if (tab == _tab) {
      _nav?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = tab);
    }
    if (tab == _Tab.search) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
    }
  }

  Future<void> _add(Future<int> Function() pick) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final added = await pick();
      if (added > 0) {
        messenger.showSnackBar(SnackBar(content: Text('Added $added ${added == 1 ? 'song' : 'songs'}')));
      }
    } on MusicPermissionDenied {
      messenger.showSnackBar(const SnackBar(content: Text('Allow OpenMusic to read your music to add a folder')));
    } catch (e) {
      debugPrint('Adding music failed: $e');
      messenger.showSnackBar(const SnackBar(content: Text('Couldn\'t add that music')));
    }
  }

  bool _compact = false;
  double _contentWidth = 0;

  /// Wraps [child] with layout facts + actions. Root-level routes (now playing,
  /// phone queue) need their own copy since they sit outside the shell tree.
  Widget _scoped(Widget child) {
    final c = PlayerScope.read(context);
    return ShellScope(
      compact: _compact,
      width: _contentWidth,
      history: _compact ? null : _history,
      open: _open,
      openCollection: (Collection col) => _open(CollectionPage(collection: col), location: Locations.collection(col)),
      openQueue: _openQueue,
      openNowPlaying: _openNowPlaying,
      openLyrics: _openLyrics,
      openDownloads: () => _open(const DownloadsPage()),
      importFromYoutube: _importFromYoutube,
      addFiles: () => _add(c.pickFiles),
      addFolder: c.canScanFolders ? () => _add(c.pickFolder) : null,
      child: child,
    );
  }

  Future<void> _importFromYoutube({String? url}) async {
    final messenger = ScaffoldMessenger.of(context);
    final queued = await showYoutubeImport(context, compact: _compact, initialUrl: url);
    if (!queued || !mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Downloading audio…'),
        action: SnackBarAction(label: 'View', onPressed: () => _open(const DownloadsPage())),
      ),
    );
  }

  /// Ctrl/Cmd+V anywhere outside a text field: a copied YouTube link opens the importer.
  Future<void> _pasteLink() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text != null && YoutubeImporter.looksLikeYoutubeUrl(text)) await _importFromYoutube(url: text);
  }

  /// Full-screen routes of the phone layout (now playing, queue, lyrics).
  /// They're built for a phone, so they close when the window becomes wide.
  final _phoneRoutes = <Route<void>>[];

  void _pushPhoneRoute(Route<void> route) {
    _phoneRoutes.add(route);
    Navigator.of(context).push(route).whenComplete(() => _phoneRoutes.remove(route));
  }

  void _closePhoneRoutes() {
    final nav = Navigator.of(context);
    for (final r in [..._phoneRoutes]) {
      if (r.isActive) nav.removeRoute(r);
    }
    _phoneRoutes.clear();
    if (mounted) setState(() {});
  }

  void _openQueue() {
    if (!_compact) return _open(const QueuePage());
    _pushPhoneRoute(MaterialPageRoute(builder: (_) => _scoped(const Scaffold(body: QueuePage()))));
  }

  void _openLyrics() {
    if (!_compact) return _open(const LyricsPage());
    _pushPhoneRoute(MaterialPageRoute(builder: (_) => _scoped(const LyricsPage(fullScreen: true))));
  }

  void _openNowPlaying() {
    _pushPhoneRoute(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => _scoped(const NowPlayingPage()),
        transitionsBuilder: (_, anim, _, child) => SlideTransition(
          position: Tween(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
          child: child,
        ),
      ),
    );
  }

  Widget _desktopNavigator() => Navigator(
    key: _history.navigatorKey,
    observers: [_history.observer],
    onGenerateRoute: (_) => _route(const HomePage(), location: Locations.home),
  );

  Widget _tabNavigator(_Tab tab) => Navigator(
    key: _navigators[tab],
    onGenerateRoute: (_) => _route(switch (tab) {
      _Tab.home => const HomePage(),
      _Tab.search => SearchPage(focusNode: _searchFocus),
      _Tab.library => const LibraryPage(),
    }),
  );

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    final size = MediaQuery.sizeOf(context);
    final width = size.width;
    // A phone keeps its layout when turned sideways (it's still held in the
    // hand); tablets and desktop windows switch by width.
    final mobile = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
    final phone = mobile && size.shortestSide < 600;
    // Stay in the phone layout for the one frame it takes to close its full-screen pages.
    final compact = width < 700 || phone || _phoneRoutes.isNotEmpty;
    if (width >= 700 && !phone && _phoneRoutes.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closePhoneRoutes());
    }
    final expanded = width >= 1200;

    _compact = compact;
    // The frame's plain title bar steps aside while this layout draws the full one.
    final ownBar = !compact && hasCustomTitleBar;
    if (titleBarInShell.value != ownBar) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) titleBarInShell.value = ownBar;
      });
    }

    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.space): c.togglePlay,
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): c.togglePlay,
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): c.next,
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): c.previous,
      const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): c.next,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): c.previous,
      const SingleActivator(LogicalKeyboardKey.arrowUp, control: true): () => c.nudgeVolume(0.05),
      const SingleActivator(LogicalKeyboardKey.arrowDown, control: true): () => c.nudgeVolume(-0.05),
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): _goSearch,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _history.back,
      const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): _history.forward,
      const SingleActivator(LogicalKeyboardKey.keyV, control: true): _pasteLink,
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _pasteLink,
      if (!compact) ...{
        const SingleActivator(LogicalKeyboardKey.f11): () => setFullScreenPlayer(!fullScreenPlayer.value),
        const SingleActivator(LogicalKeyboardKey.escape): () => setFullScreenPlayer(false),
      },
    };

    // Phone only: one stack per bottom tab, fading between tabs. The hidden
    // tabs' tickers are off: no animation runs there (a playing song's bars in
    // a list nobody sees kept the screen redrawing), and they catch up on what
    // changed when shown.
    Widget tabs() => _FadeOnChange(
      index: _tab.index,
      child: IndexedStack(
        index: _tab.index,
        children: [for (final t in _Tab.values) TickerMode(enabled: t == _tab, child: _tabNavigator(t))],
      ),
    );

    final Widget body;
    if (compact) {
      // Sideways the tabs move to a rail on the left, leaving the height to the pages.
      final sideways = width > size.height && size.height < 500;
      final insets = MediaQuery.paddingOf(context);
      _contentWidth = sideways ? width - _SideTabs.width - insets.left - insets.right : width;
      // The desktop history stays alive (hidden) while the window is narrow,
      // so widening it again returns to the same page.
      final pages = Stack(
        children: [
          Positioned.fill(child: tabs()),
          // Full size even while hidden: laid out at width 0 its pages would break.
          Positioned.fill(
            child: Offstage(child: TickerMode(enabled: false, child: _desktopNavigator())),
          ),
        ],
      );
      body = _scoped(
        Scaffold(
          // Pages scroll on under the see-through tab bar; they pad their ends by its height.
          extendBody: true,
          body: sideways
              ? Row(
                  children: [
                    _SideTabs(tab: _tab, onSelect: _selectTab),
                    Expanded(
                      // The rail took the left inset; a camera cutout on the right stays clear.
                      child: SafeArea(
                        left: false,
                        top: false,
                        bottom: false,
                        child: MediaQuery.removePadding(context: context, removeLeft: true, child: pages),
                      ),
                    ),
                  ],
                )
              : pages,
          bottomNavigationBar: _BottomBar(
            mini: MiniPlayer(onOpen: _openNowPlaying),
            tab: _tab,
            onSelect: _selectTab,
            showTabs: !sideways,
          ),
        ),
      );
    } else {
      final sidebarWidth = expanded ? 300.0 : 84.0;
      final sideOpen = expanded && _sidePanel && _hasTrack;
      _contentWidth = width - sidebarWidth - (sideOpen ? 340 : 0) - 24;
      body = _scoped(
        Scaffold(
          // In the bottom slot so floating snackbars stack above the player instead of covering it.
          bottomNavigationBar: SafeArea(
            top: false,
            child: DesktopPlayerBar(
              sidePanelOpen: sideOpen,
              onToggleSidePanel: expanded ? () => setState(() => _sidePanel = !_sidePanel) : null,
            ),
          ),
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (hasCustomTitleBar)
                  ValueListenableBuilder(
                    valueListenable: fullScreenPlayer,
                    builder: (context, full, bar) => full ? const SizedBox.shrink() : bar!,
                    child: _titleBar(),
                  ),
                Expanded(
                  // Full-screen player on top; the pages stay alive (and their history) underneath.
                  child: ValueListenableBuilder(
                    valueListenable: fullScreenPlayer,
                    builder: (context, full, pages) => Stack(
                      children: [
                        Positioned.fill(
                          child: Offstage(offstage: full, child: pages),
                        ),
                        if (full) const Positioned.fill(child: FullScreenPlayer()),
                      ],
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(8, hasCustomTitleBar ? 0 : 8, 8, 0),
                      child: Row(
                        children: [
                          SizedBox(
                            width: sidebarWidth,
                            child: ListenableBuilder(
                              listenable: _history,
                              builder: (context, _) => _Sidebar(
                                collapsed: !expanded,
                                location: _history.location,
                                onHome: _goHome,
                                onSearch: _goSearch,
                                // Home and search sit in the title bar instead.
                                inTitleBar: hasCustomTitleBar,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: _Panel(child: _desktopNavigator())),
                          if (expanded)
                            _SlidingPanel(
                              open: sideOpen,
                              child: _Panel(
                                child: NowPlayingSidePanel(onClose: () => setState(() => _sidePanel = false)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Listener(
      // Mouse side buttons step through the history, as in a browser.
      onPointerDown: (e) {
        if (_compact) return;
        if (e.buttons & kBackMouseButton != 0) _history.back();
        if (e.buttons & kForwardMouseButton != 0) _history.forward();
      },
      // A scope, so focus leaving the title bar's search box lands here (where Space plays) and not above.
      child: FocusScope(autofocus: true, onKeyEvent: (node, event) => _handleShortcut(event, shortcuts), child: body),
    );
  }

  /// App-wide shortcuts, except while typing: Space, Ctrl+V etc. must reach text fields.
  /// (A CallbackShortcuts here would sit between a TextField and the app's
  /// default text-editing shortcuts and swallow them.)
  KeyEventResult _handleShortcut(KeyEvent event, Map<ShortcutActivator, VoidCallback> shortcuts) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus?.context;
    final typing =
        focused != null &&
        (focused.widget is EditableText || focused.findAncestorWidgetOfExactType<EditableText>() != null);
    if (typing) return KeyEventResult.ignored;
    for (final entry in shortcuts.entries) {
      if (entry.key.accepts(event, HardwareKeyboard.instance)) {
        entry.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }
}

/// Fades the tab content in when switching tabs (the stack keeps each tab's state).
class _FadeOnChange extends StatefulWidget {
  const _FadeOnChange({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_FadeOnChange> createState() => _FadeOnChangeState();
}

class _FadeOnChangeState extends State<_FadeOnChange> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1);

  @override
  void didUpdateWidget(_FadeOnChange old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _fade.forward(from: 0);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
    child: widget.child,
  );
}

/// The now-playing side panel, sliding open and shut instead of popping.
class _SlidingPanel extends StatelessWidget {
  const _SlidingPanel({required this.open, required this.child});

  static const width = 332.0;
  static const gap = 8.0;

  final bool open;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: open ? 1 : 0),
    duration: const Duration(milliseconds: 280),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => t == 0
        ? const SizedBox.shrink()
        : SizedBox(
            width: (width + gap) * t,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: width + gap,
                maxWidth: width + gap,
                child: Opacity(opacity: t, child: child),
              ),
            ),
          ),
    child: Padding(
      padding: const EdgeInsets.only(left: gap),
      child: child,
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    // Material (not ColoredBox) so ink splashes from InkWells inside stay visible.
    child: Material(color: AppColors.panel, child: child),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.collapsed,
    required this.location,
    required this.onHome,
    required this.onSearch,
    this.inTitleBar = false,
  });

  final bool collapsed;
  final bool inTitleBar;

  /// What's on screen, so its entry can be highlighted.
  final String location;
  final VoidCallback onHome;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget item(String where, IconData icon, IconData selectedIcon, String label, VoidCallback onTap) {
      final selected = location == where;
      final color = selected ? AppColors.textPrimary : AppColors.textSecondary;
      final row = InkWell(
        borderRadius: BorderRadius.circular(6),
        hoverColor: Colors.transparent,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Icon(selected ? selectedIcon : icon, color: color, size: 26),
              if (!collapsed) ...[
                const SizedBox(width: 18),
                Text(
                  label,
                  style: text.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
        ),
      );
      return collapsed ? Tooltip(message: label, child: row) : row;
    }

    // With the title bar, Home and search sit in it and Downloads / Settings in its ⋯ menu.
    final navItems = [
      if (!inTitleBar) ...[
        item(Locations.home, Icons.home_outlined, Icons.home_rounded, 'Home', onHome),
        item(Locations.search, Icons.search_rounded, Icons.manage_search_rounded, 'Search', onSearch),
        _DownloadsLink(collapsed: collapsed, selected: location == Locations.downloads),
        item(Locations.settings, Icons.settings_outlined, Icons.settings_rounded, 'Settings', () {
          if (location != Locations.settings) ShellScope.of(context).open(const SettingsPage());
        }),
      ],
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Short windows can't fit the nav and a usable library list: collapse into
        // one scrolling panel and reach the library through a link instead.
        if (constraints.maxHeight < 440) {
          return _Panel(
            child: SmoothScroll(
              builder: (context, scroll) => ListView(
                controller: scroll,
                padding: const EdgeInsets.all(8),
                children: [
                  ...navItems,
                  _NavLink(
                    collapsed: collapsed,
                    icon: Icons.video_library_outlined,
                    label: 'Your Library',
                    onTap: () => ShellScope.of(context).open(const LibraryPage()),
                  ),
                ],
              ),
            ),
          );
        }
        return Column(
          children: [
            if (navItems.isNotEmpty) ...[
              _Panel(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(children: navItems),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: _Panel(child: LibraryList(dense: true, collapsed: collapsed)),
            ),
          ],
        );
      },
    );
  }
}

/// Sidebar entry that opens a page (rather than switching tab).
class _NavLink extends StatelessWidget {
  const _NavLink({required this.collapsed, required this.icon, required this.label, required this.onTap});

  final bool collapsed;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final row = InkWell(
      borderRadius: BorderRadius.circular(6),
      hoverColor: Colors.transparent,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.textSecondary, size: 26),
            if (!collapsed) ...[
              const SizedBox(width: 18),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(color: AppColors.textSecondary, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return collapsed ? Tooltip(message: label, child: row) : row;
  }
}

/// The title bar's ⋯ button: Downloads and Settings. A ring around it shows
/// downloads in progress.
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.onDownloads, required this.onSettings});

  final VoidCallback onDownloads;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: c.youtube,
      builder: (context, _) {
        final progress = c.youtube.activeProgress;
        // Compact, like a desktop app's menu: short rows, small text and icons.
        PopupMenuItem<VoidCallback> entry(IconData icon, String label, VoidCallback onTap, {Widget? trailing}) =>
            PopupMenuItem(
              value: onTap,
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: text.bodyMedium?.copyWith(fontSize: 13, color: AppColors.textPrimary),
              child: Row(
                children: [
                  Icon(icon, size: 17, color: AppColors.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(label)),
                  ?trailing,
                ],
              ),
            );
        return PopupMenuButton<VoidCallback>(
          // Over the whole window, so a click anywhere closes it.
          useRootNavigator: true,
          tooltip: 'More',
          position: PopupMenuPosition.under,
          constraints: const BoxConstraints(minWidth: 180),
          menuPadding: const EdgeInsets.symmetric(vertical: 4),
          onSelected: (open) => open(),
          style: IconButton.styleFrom(
            foregroundColor: AppColors.textPrimary,
            minimumSize: const Size(36, 36),
            fixedSize: const Size(36, 36),
            padding: EdgeInsets.zero,
          ),
          icon: Stack(
            alignment: Alignment.center,
            children: [
              if (progress != null)
                SizedBox.square(
                  dimension: 28,
                  child: CircularProgressIndicator(
                    value: progress == 0 ? null : progress,
                    strokeWidth: 2,
                    color: AppColors.accent,
                    backgroundColor: AppColors.hover,
                  ),
                ),
              const Icon(Icons.more_horiz_rounded, size: 24),
            ],
          ),
          itemBuilder: (context) => [
            entry(
              Icons.download_rounded,
              'Downloads',
              onDownloads,
              trailing: progress == null
                  ? null
                  : Text(
                      '${c.youtube.activeCount}',
                      style: text.labelSmall?.copyWith(color: AppColors.accent, fontWeight: FontWeight.w700),
                    ),
            ),
            entry(Icons.settings_outlined, 'Settings', onSettings),
          ],
        );
      },
    );
  }
}

/// Sidebar entry for YouTube downloads, with a progress ring while busy.
class _DownloadsLink extends StatelessWidget {
  const _DownloadsLink({required this.collapsed, required this.selected});

  final bool collapsed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.read(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: c.youtube,
      builder: (context, _) {
        final progress = c.youtube.activeProgress;
        final row = InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: Colors.transparent,
          onTap: selected ? null : shell.openDownloads,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                SizedBox.square(
                  dimension: 26,
                  child: progress == null
                      ? Icon(
                          Icons.download_rounded,
                          color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                          size: 26,
                        )
                      : Padding(
                          padding: const EdgeInsets.all(3),
                          child: CircularProgressIndicator(
                            value: progress == 0 ? null : progress,
                            strokeWidth: 2.5,
                            color: AppColors.accent,
                            backgroundColor: AppColors.hover,
                          ),
                        ),
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 18),
                  Expanded(
                    child: Text(
                      'Downloads',
                      style: text.titleMedium?.copyWith(
                        color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (progress != null)
                    Text(
                      '${c.youtube.activeCount}',
                      style: text.labelLarge?.copyWith(color: AppColors.accent, fontWeight: FontWeight.w700),
                    ),
                ],
              ],
            ),
          ),
        );
        return collapsed ? Tooltip(message: 'Downloads', child: row) : row;
      },
    );
  }
}

/// Phone bottom area: mini player floating over a fade-to-black tab bar.
const _tabItems = [
  (tab: _Tab.home, icon: Icons.home_outlined, selected: Icons.home_rounded, label: 'Home'),
  (tab: _Tab.search, icon: Icons.search_rounded, selected: Icons.manage_search_rounded, label: 'Search'),
  (tab: _Tab.library, icon: Icons.library_music_outlined, selected: Icons.library_music_rounded, label: 'Your Library'),
];

/// The phone's tabs as a rail down the left, for a phone held sideways.
class _SideTabs extends StatelessWidget {
  const _SideTabs({required this.tab, required this.onSelect});

  static const width = 88.0;

  final _Tab tab;
  final ValueChanged<_Tab> onSelect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      right: false,
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              for (final i in _tabItems)
                InkResponse(
                  onTap: () => onSelect(i.tab),
                  radius: 36,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: SizedBox(
                      width: width,
                      child: Column(
                        children: [
                          Icon(
                            tab == i.tab ? i.selected : i.icon,
                            color: tab == i.tab ? AppColors.textPrimary : AppColors.textSecondary,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            i.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(
                              color: tab == i.tab ? AppColors.textPrimary : AppColors.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
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

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.mini, required this.tab, required this.onSelect, this.showTabs = true});

  final Widget mini;
  final _Tab tab;
  final ValueChanged<_Tab> onSelect;

  /// Off when the tabs sit in [_SideTabs] instead.
  final bool showTabs;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final glass = Appearance.instance.glass;
    final bar = SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          mini,
          if (showTabs)
            Row(
              children: [
                for (final i in _tabItems)
                  Expanded(
                    child: InkResponse(
                      onTap: () => onSelect(i.tab),
                      radius: 36,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              tab == i.tab ? i.selected : i.icon,
                              color: tab == i.tab ? AppColors.textPrimary : AppColors.textSecondary,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              i.label,
                              style: text.labelSmall?.copyWith(
                                color: tab == i.tab ? AppColors.textPrimary : AppColors.textSecondary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
    if (glass) {
      // Frosted: the page shows through, blurred, behind both the mini player and the tabs.
      return ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: Appearance.instance.blur, sigmaY: Appearance.instance.blur),
          child: ColoredBox(color: AppColors.solidBackground.withValues(alpha: 0.55), child: bar),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.solidBackground.withValues(alpha: 0),
            AppColors.solidBackground.withValues(alpha: 0.9),
            AppColors.solidBackground,
          ],
          stops: const [0, 0.35, 1],
        ),
      ),
      child: bar,
    );
  }
}
