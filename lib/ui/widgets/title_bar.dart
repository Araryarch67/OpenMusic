import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';

/// Desktop platforms draw their own title bar; mobile has none.
bool get hasCustomTitleBar => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// Draggable app-coloured title bar with window buttons.
/// macOS keeps its native traffic lights (TitleBarStyle.hidden overlays them),
/// so we only reserve room for them there.
class AppTitleBar extends StatefulWidget {
  const AppTitleBar({super.key});

  static const height = 36.0;

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
    return SizedBox(
      height: AppTitleBar.height,
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
                    const Icon(Icons.graphic_eq_rounded, size: 16, color: AppColors.accent),
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
          if (!Platform.isMacOS) ...[
            _WindowButton(tooltip: 'Minimize', icon: Icons.remove_rounded, onPressed: windowManager.minimize),
            _WindowButton(
              tooltip: _maximized ? 'Restore' : 'Maximize',
              icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
              iconSize: _maximized ? 13 : 15,
              onPressed: _toggleMaximize,
            ),
            _WindowButton(tooltip: 'Close', icon: Icons.close_rounded, onPressed: windowManager.close, danger: true),
          ],
        ],
      ),
    );
  }
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
            height: AppTitleBar.height,
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
