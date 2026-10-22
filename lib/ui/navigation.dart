import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track.dart';
import 'theme.dart';

/// Identifies a screen, so the sidebar can highlight where you are.
abstract final class Locations {
  static const home = 'home';
  static const search = 'search';
  static const downloads = 'downloads';
  static const settings = 'settings';
  static const library = 'library';

  static String settingsTopic(String name) => 'settings:$name';
  static String collection(Collection c) => 'collection:${c.kind.name}:${c.title}';
  static String remotePlaylist(String id) => 'playlist:$id';
}

/// Desktop navigation: one history, like a web browser.
///
/// Every screen opened from anywhere (sidebar, a card, a link) goes on top of
/// the same stack, so Back always returns to the screen you saw before and
/// Forward redoes it. (Phones keep one stack per bottom tab instead, the
/// usual mobile pattern.)
class DesktopHistory extends ChangeNotifier {
  DesktopHistory({required this.routeBuilder});

  final Route<void> Function(Widget page, String location) routeBuilder;

  final navigatorKey = GlobalKey<NavigatorState>();
  late final NavigatorObserver observer = _HistoryObserver(this);

  final _stack = <Route<dynamic>>[];
  final _forward = <(String, Widget)>[];

  NavigatorState? get _nav => navigatorKey.currentState;

  /// The screen on top.
  String get location => _stack.lastOrNull?.settings.name ?? Locations.home;

  bool get canGoBack => _stack.length > 1;
  bool get canGoForward => _forward.isNotEmpty;

  /// Opens [page] as a new step in the history (forward steps are dropped, as in a browser).
  void open(Widget page, String location) {
    final nav = _nav;
    if (nav == null || location == this.location) return; // already there: no duplicate step
    _forward.clear();
    // One search box at a time: an older search screen further back is replaced, not duplicated.
    if (location == Locations.search) {
      for (final r in [..._stack.where((r) => r.settings.name == Locations.search && r != _stack.first)]) {
        nav.removeRoute(r);
      }
    }
    nav.push(routeBuilder(page, location));
  }

  void back() {
    final nav = _nav;
    final top = _stack.lastOrNull;
    if (nav == null || top == null || !canGoBack) return;
    final page = top.settings.arguments;
    if (page is Widget) _forward.add((top.settings.name ?? '', page));
    nav.pop();
  }

  void forward() {
    if (_forward.isEmpty) return;
    final (location, page) = _forward.removeLast();
    _nav?.push(routeBuilder(page, location));
  }

  void _changed() => scheduleMicrotask(notifyListeners);
}

class _HistoryObserver extends NavigatorObserver {
  _HistoryObserver(this.history);

  final DesktopHistory history;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PageRoute) return;
    history._stack.add(route);
    history._changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (history._stack.remove(route)) history._changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (history._stack.remove(route)) history._changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : history._stack.indexOf(oldRoute);
    if (i >= 0 && newRoute != null) history._stack[i] = newRoute;
    history._changed();
  }
}

/// Back / Forward arrows, always in the same place at the top left of a page.
class HistoryButtons extends StatelessWidget {
  const HistoryButtons({super.key, required this.history});

  final DesktopHistory history;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: history,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Arrow(icon: Icons.chevron_left_rounded, tooltip: 'Back', onPressed: history.canGoBack ? history.back : null),
        const SizedBox(width: 4),
        _Arrow(
          icon: Icons.chevron_right_rounded,
          tooltip: 'Forward',
          onPressed: history.canGoForward ? history.forward : null,
        ),
      ],
    ),
  );
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    // Plain chevrons in the title bar, like a browser's.
    style: IconButton.styleFrom(
      foregroundColor: AppColors.textPrimary,
      disabledForegroundColor: AppColors.textMuted,
      minimumSize: const Size(36, 36),
      fixedSize: const Size(36, 36),
      padding: EdgeInsets.zero,
    ),
    icon: Icon(icon, size: 28),
  );
}

/// Highlights a sidebar entry while its screen is the one showing.
class SelectedHighlight extends StatelessWidget {
  const SelectedHighlight({super.key, required this.history, required this.location, required this.child});

  final DesktopHistory? history;
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final h = history;
    if (h == null) return child;
    return ListenableBuilder(
      listenable: h,
      builder: (context, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: h.location == location ? AppColors.hover : AppColors.hover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      ),
      child: child,
    );
  }
}
