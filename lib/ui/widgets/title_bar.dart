import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';
import 'app_logo.dart';

/// Desktop platforms draw their own title bar; mobile has none.
bool get hasCustomTitleBar => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// True while the desktop layout draws the title bar itself (with Back /
/// Forward, Home and search in it); the app frame then leaves its plain one out.
final titleBarInShell = ValueNotifier<bool>(false);

/// Draggable app-coloured title bar with window buttons.
/// macOS keeps its native traffic lights (TitleBarStyle.hidden overlays them),
/// so we only reserve room for them there.
///
/// [leading] and [center] fill it in the desktop layout; without them it shows
/// the app's name. The empty space around them drags the window.
class AppTitleBar extends StatefulWidget {
  const AppTitleBar({super.key, this.leading, this.center, this.height = AppTitleBar.plainHeight});

  static const plainHeight = 36.0;

  /// With Back / Forward and the search box in it.
  static const tallHeight = 64.0;

  final Widget? leading;
  final Widget? center;
  final double height;

  @override
  State<AppTitleBar> createState() => _AppTitleBarState();
}

class _AppTitleBarState extends State<AppTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _sync();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _sync() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (mounted && maximized != _maximized) setState(() => _maximized = maximized);
    } catch (_) {
      // No window plugin (e.g. widget tests).
    }
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  void onWindowResized() => _sync();

  Future<void> _toggleMaximize() async =>
      await windowManager.isMaximized() ? windowManager.unmaximize() : windowManager.maximize();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget drag(Widget child) => GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: _toggleMaximize,
      child: child,
    );
    if (widget.center != null || widget.leading != null) {
      // The centre piece sits in the middle of the window, whatever the sides hold.
      return SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            Positioned.fill(child: drag(const SizedBox.expand())),
            Positioned.fill(
              child: Row(
                children: [
                  SizedBox(width: Platform.isMacOS ? 80 : 12),
                  ?widget.leading,
                  const Spacer(),
                  if (!Platform.isMacOS) ..._windowButtons(),
                ],
              ),
            ),
            if (widget.center != null)
              Center(
                child: FractionallySizedBox(widthFactor: 0.5, child: Center(child: widget.center)),
              ),
          ],
        ),
      );
    }
    return SizedBox(
      height: widget.height,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: _toggleMaximize,
              child: Padding(
                padding: EdgeInsets.only(left: Platform.isMacOS ? 80 : 14),
                child: Row(
                  children: [
                    const AppLogo(size: 16),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'OpenMusic',
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: text.labelLarge?.copyWith(color: AppColors.textSecondary, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!Platform.isMacOS) ..._windowButtons(),
        ],
      ),
    );
  }

  List<Widget> _windowButtons() => [
    _WindowButton(tooltip: 'Minimize', icon: Icons.remove_rounded, onPressed: windowManager.minimize),
    _WindowButton(
      tooltip: _maximized ? 'Restore' : 'Maximize',
      icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
      iconSize: _maximized ? 13 : 15,
      onPressed: _toggleMaximize,
    ),
    _WindowButton(tooltip: 'Close', icon: Icons.close_rounded, onPressed: windowManager.close, danger: true),
  ];
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.iconSize = 16,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final double iconSize;
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Semantics instead of Tooltip: the title bar lives above the Navigator's Overlay.
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 46,
            height: AppTitleBar.plainHeight,
            color: _hover ? (widget.danger ? const Color(0xFFC42B1C) : AppColors.hover) : Colors.transparent,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hover ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
