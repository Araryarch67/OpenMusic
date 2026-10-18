import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/track.dart';
import '../services/player_controller.dart';
import 'pages/collection_page.dart';
import 'pages/downloads_page.dart';
import 'pages/home_page.dart';
import 'pages/library_page.dart';
import 'pages/queue_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'player_panels.dart';
import 'shell_scope.dart';
import 'theme.dart';
import 'widgets/source_switch.dart';
import 'youtube_import.dart';
import '../services/youtube_importer.dart';

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
  final _navigators = {for (final t in _Tab.values) t: GlobalKey<NavigatorState>()};

  NavigatorState? get _nav => _navigators[_tab]!.currentState;

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  void _open(Widget page) {
    // The library tab has no page stack of its own on wide layouts; reuse Home's.
    if (_tab == _Tab.library && MediaQuery.sizeOf(context).width >= 700) setState(() => _tab = _Tab.home);
    WidgetsBinding.instance.addPostFrameCallback((_) => _nav?.push(_route(page)));
  }

  static Route<void> _route(Widget page) => PageRouteBuilder(
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
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t add music: $e')));
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
      open: _open,
      openCollection: (Collection col) => _open(CollectionPage(collection: col)),
      openQueue: _openQueue,
      openNowPlaying: _openNowPlaying,
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
        action: SnackBarAction(label: 'View', textColor: Colors.black, onPressed: () => _open(const DownloadsPage())),
      ),
    );
  }

  /// Ctrl/Cmd+V anywhere outside a text field: a copied YouTube link opens the importer.
  Future<void> _pasteLink() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text != null && YoutubeImporter.looksLikeYoutubeUrl(text)) await _importFromYoutube(url: text);
  }

  void _openQueue() {
    if (!_compact) return _open(const QueuePage());
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => _scoped(const Scaffold(body: QueuePage()))));
  }

  void _openNowPlaying() {
    Navigator.of(context).push(
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
    final c = PlayerScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 700;
    final expanded = width >= 1200;

    _compact = compact;

    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.space): c.togglePlay,
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): c.togglePlay,
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): c.next,
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): c.previous,
      const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): c.next,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): c.previous,
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => _selectTab(_Tab.search),
      const SingleActivator(LogicalKeyboardKey.keyV, control: true): _pasteLink,
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _pasteLink,
    };

    final pages = IndexedStack(index: _tab.index, children: [for (final t in _Tab.values) _tabNavigator(t)]);

    final Widget body;
    if (compact) {
      _contentWidth = width;
      body = _scoped(
        Scaffold(
          body: pages,
          bottomNavigationBar: _BottomBar(
            mini: MiniPlayer(onOpen: _openNowPlaying),
            tab: _tab,
            onSelect: _selectTab,
          ),
        ),
      );
    } else {
      final sidebarWidth = expanded ? 300.0 : 84.0;
      final sideOpen = expanded && _sidePanel && c.currentTrack != null;
      _contentWidth = width - sidebarWidth - (sideOpen ? 340 : 0) - 24;
      // Library tab lives in the sidebar on wide layouts.
      if (_tab == _Tab.library) _tab = _Tab.home;
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
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Row(
                      children: [
                        SizedBox(
                          width: sidebarWidth,
                          child: _Sidebar(collapsed: !expanded, tab: _tab, onSelect: _selectTab),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: _Panel(child: pages)),
                        if (sideOpen) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 332,
                            child: _Panel(
                              child: NowPlayingSidePanel(onClose: () => setState(() => _sidePanel = false)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Focus(autofocus: true, onKeyEvent: (node, event) => _handleShortcut(event, shortcuts), child: body);
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
  const _Sidebar({required this.collapsed, required this.tab, required this.onSelect});

  final bool collapsed;
  final _Tab tab;
  final ValueChanged<_Tab> onSelect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget item(_Tab t, IconData icon, IconData selectedIcon, String label) {
      final selected = tab == t;
      final color = selected ? AppColors.textPrimary : AppColors.textSecondary;
      final row = InkWell(
        borderRadius: BorderRadius.circular(6),
        hoverColor: Colors.transparent,
        onTap: () => onSelect(t),
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

    final navItems = [
      Padding(
        padding: EdgeInsets.fromLTRB(collapsed ? 0 : 8, 4, 8, 8),
        child: Align(
          alignment: collapsed ? Alignment.center : Alignment.centerLeft,
          child: SourceSwitch(collapsed: collapsed),
        ),
      ),
      item(_Tab.home, Icons.home_outlined, Icons.home_rounded, 'Home'),
      item(_Tab.search, Icons.search_rounded, Icons.manage_search_rounded, 'Search'),
      _DownloadsLink(collapsed: collapsed),
      _NavLink(
        collapsed: collapsed,
        icon: Icons.settings_outlined,
        label: 'Settings',
        onTap: () => ShellScope.of(context).open(const SettingsPage()),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Short windows can't fit the nav and a usable library list: collapse into
        // one scrolling panel and reach the library through a link instead.
        if (constraints.maxHeight < 440) {
          return _Panel(
            child: ListView(
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
          );
        }
        return Column(
          children: [
            _Panel(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(children: navItems),
              ),
            ),
            const SizedBox(height: 8),
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

/// Sidebar entry for YouTube downloads, with a progress ring while busy.
class _DownloadsLink extends StatelessWidget {
  const _DownloadsLink({required this.collapsed});

  final bool collapsed;

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
          onTap: shell.openDownloads,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                SizedBox.square(
                  dimension: 26,
                  child: progress == null
                      ? const Icon(Icons.download_rounded, color: AppColors.textSecondary, size: 26)
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
                      style: text.titleMedium?.copyWith(color: AppColors.textSecondary, fontWeight: FontWeight.w700),
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
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.mini, required this.tab, required this.onSelect});

  final Widget mini;
  final _Tab tab;
  final ValueChanged<_Tab> onSelect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const items = [
      (tab: _Tab.home, icon: Icons.home_outlined, selected: Icons.home_rounded, label: 'Home'),
      (tab: _Tab.search, icon: Icons.search_rounded, selected: Icons.manage_search_rounded, label: 'Search'),
      (
        tab: _Tab.library,
        icon: Icons.library_music_outlined,
        selected: Icons.library_music_rounded,
        label: 'Your Library',
      ),
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xE6000000), Colors.black],
          stops: [0, 0.35, 1],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            mini,
            Row(
              children: [
                for (final i in items)
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
      ),
    );
  }
}
