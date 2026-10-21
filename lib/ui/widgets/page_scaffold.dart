import 'package:flutter/material.dart';

import '../shell_scope.dart';
import '../theme.dart';
import 'smooth_scroll.dart';

/// Scrolling page with a top colour wash and a sticky title bar that fades in on scroll.
class PageScaffold extends StatefulWidget {
  const PageScaffold({super.key, required this.slivers, this.gradientColor, this.title, this.actions = const []});

  final List<Widget> slivers;
  final Color? gradientColor;
  final String? title;
  final List<Widget> actions;

  @override
  State<PageScaffold> createState() => _PageScaffoldState();
}

class _PageScaffoldState extends State<PageScaffold> {
  final _scroll = SmoothScrollController();
  double _offset = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final o = _scroll.offset.clamp(0.0, 300.0);
      if ((o - _offset).abs() > 4 || o == 0 || o == 300) setState(() => _offset = o);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final color = widget.gradientColor ?? AppColors.elevated;
    // Pages below this one, not above: Navigator.canPop() goes stale on a root page rebuilt while covered.
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    // Desktop: Back / Forward live in the title bar; the bar here only carries the title.
    final history = shell.history;
    final showBar = history != null || canPop || widget.actions.isNotEmpty;
    final barOpacity = ((_offset - 180) / 80).clamp(0.0, 1.0);
    const barHeight = 56.0;
    final topInset = shell.compact ? MediaQuery.paddingOf(context).top : 0.0;

    return Material(
      color: AppColors.panel,
      child: Stack(
        children: [
          // Colour wash behind the header.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 420,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [color.withValues(alpha: 0.85), color.withValues(alpha: 0.25), AppColors.panel],
                  stops: const [0, 0.55, 1],
                ),
              ),
            ),
          ),
          CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: topInset + (showBar ? barHeight : 8))),
              ...widget.slivers,
              // Clears the phone's floating player and tab bar.
              SliverToBoxAdapter(child: SizedBox(height: 32 + MediaQuery.paddingOf(context).bottom)),
            ],
          ),
          // Sticky top bar.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            // Only the buttons take clicks: the bar's empty area must not swallow
            // taps meant for what scrolls under it (e.g. the search box).
            child: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(color: Color.lerp(color, Colors.black, 0.45)!.withValues(alpha: barOpacity)),
                  ),
                ),
                Container(
                  height: (showBar ? barHeight : 8) + topInset,
                  padding: EdgeInsets.only(top: topInset, left: 8, right: 8),
                  child: Row(
                    children: [
                      if (history == null && canPop)
                        IconButton.filled(
                          tooltip: 'Back',
                          style: IconButton.styleFrom(backgroundColor: Colors.black45, foregroundColor: Colors.white),
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: IgnorePointer(
                          child: Opacity(
                            opacity: barOpacity,
                            child: Text(
                              widget.title ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                      ),
                      ...widget.actions,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.onShowAll});

  final String title;
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(shell.compact ? 16 : 24, 24, shell.compact ? 8 : 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          ),
          if (onShowAll != null)
            TextButton(
              onPressed: onShowAll,
              style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
              child: const Text('Show all'),
            ),
        ],
      ),
    );
  }
}
