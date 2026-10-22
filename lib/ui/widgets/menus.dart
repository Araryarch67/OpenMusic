import 'package:flutter/material.dart';

import '../theme.dart';

/// Menus and pickers share one look: a dark rounded card with a hairline
/// border, compact rows with an icon.
BorderSide get _menuBorder => BorderSide(color: AppColors.border);
final menuShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: _menuBorder);

/// One row of a popup menu: icon and label, sized for both mouse and touch.
class MenuRow extends StatelessWidget {
  const MenuRow({super.key, required this.leading, required this.title});

  final Widget leading;
  final Widget title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconTheme.merge(
        data: IconThemeData(size: 20, color: AppColors.textSecondary),
        child: leading,
      ),
      const SizedBox(width: 14),
      Expanded(
        child: DefaultTextStyle.merge(
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          child: title,
        ),
      ),
    ],
  );
}

/// A choice from a short list: a rounded pill showing the current option,
/// opening a menu with a check by the selected one. Replaces DropdownButton.
class OptionPicker<T> extends StatelessWidget {
  const OptionPicker({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.maxWidth = 240,
  });

  final T value;
  final List<(T, String)> options;

  /// Null disables the picker.
  final ValueChanged<T>? onChanged;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final enabled = onChanged != null;
    final current = options.where((o) => o.$1 == value).firstOrNull?.$2 ?? '';
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(AppColors.menu),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(menuShape),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor: const WidgetStatePropertyAll(Colors.black),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
        maximumSize: const WidgetStatePropertyAll(Size(360, 420)),
      ),
      menuChildren: [
        for (final (v, label) in options)
          MenuItemButton(
            onPressed: () => onChanged?.call(v),
            style: MenuItemButton.styleFrom(
              minimumSize: const Size(200, 44),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              foregroundColor: AppColors.textPrimary,
            ),
            leadingIcon: SizedBox(
              width: 20,
              child: v == value ? Icon(Icons.check_rounded, size: 18, color: AppColors.accent) : null,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(
                  fontWeight: v == value ? FontWeight.w700 : FontWeight.w500,
                  color: v == value ? AppColors.accent : AppColors.textPrimary,
                ),
              ),
            ),
          ),
      ],
      builder: (context, controller, _) => Material(
        color: AppColors.hover.withValues(alpha: enabled ? 1 : 0.5),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? () => controller.isOpen ? controller.close() : controller.open() : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 9, 10, 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Text(
                    current,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: enabled ? AppColors.textPrimary : AppColors.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: controller.isOpen ? 0.5 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 20,
                    color: enabled ? AppColors.textSecondary : AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
