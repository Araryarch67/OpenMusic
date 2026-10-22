import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/appearance.dart';

/// Colour tokens of the theme picked in Settings › Appearance ([ThemeChoice]).
abstract final class AppColors {
  static AppPalette get _p => Appearance.instance.palette;

  /// Whether the theme is light (dark text on light surfaces).
  static bool get light => _p.light;

  /// Window and panel backgrounds; see-through when the window opacity
  /// setting is below 100%.
  static Color get background => _p.background.withValues(alpha: Appearance.instance.windowOpacity);
  static Color get panel => _p.panel.withValues(alpha: Appearance.instance.windowOpacity);

  /// [background] and [panel] without the window's opacity.
  static Color get solidBackground => _p.background;
  static Color get elevated => _p.elevated;
  static Color get hover => _p.hover;

  /// Popup menus and pickers.
  static Color get menu => _p.menu;
  static Color get textPrimary => _p.textPrimary;
  static Color get textSecondary => _p.textSecondary;
  static Color get textMuted => _p.textMuted;

  /// A faint fill over any surface (search box, cards on hover).
  static Color get tile => _p.textPrimary.withValues(alpha: 0.08);

  /// Hairline borders and dividers.
  static Color get border => _p.textPrimary.withValues(alpha: 0.10);
  static Color get divider => _p.textPrimary.withValues(alpha: 0.06);

  /// The strongest contrast: a filled button or the phone's search box (white on dark themes).
  static Color get inverse => _p.textPrimary;
  static Color get onInverse => _p.light ? _p.panel : _p.background;

  static Color get accent => Appearance.instance.accentColor;
  static Color get onAccent => Appearance.instance.onAccentColor;

  /// A cover's colour as a page header wash: strong on dark themes, soft on light ones
  /// (where the text over it is dark).
  static double get washStrength => _p.light ? 0.4 : 1;

  /// [color] darkened toward the theme's background by [amount] (lightened on light themes).
  static Color sink(Color color, double amount) => Color.lerp(color, _p.background, _p.light ? 0.75 : amount)!;
}

bool get _desktop => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

ThemeData buildAppTheme({String? fontFamily}) {
  final brightness = AppColors.light ? Brightness.light : Brightness.dark;
  final base = ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: brightness,
      primary: AppColors.accent,
      onPrimary: AppColors.onAccent,
      surface: AppColors.panel,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textSecondary,
    ),
    scaffoldBackgroundColor: AppColors.background,
    splashFactory: InkSparkle.splashFactory,
    // google_fonts 9 builds on package:material_ui, so only take the family name
    // (which also kicks off the font download) rather than its TextTheme type.
    fontFamily: fontFamily ?? GoogleFonts.figtree().fontFamily,
  );
  final text = base.textTheme.apply(bodyColor: AppColors.textPrimary, displayColor: AppColors.textPrimary);
  return base.copyWith(
    textTheme: text,
    iconTheme: IconThemeData(color: AppColors.textSecondary),
    appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: AppColors.textPrimary,
      inactiveTrackColor: AppColors.textPrimary.withValues(alpha: 0.3),
      thumbColor: AppColors.textPrimary,
      overlayColor: AppColors.textPrimary.withValues(alpha: 0.12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 0),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      trackShape: const RoundedRectSliderTrackShape(),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.hover,
      selectedColor: AppColors.textPrimary,
      // Material 3 ignores secondaryLabelStyle: the selected (inverse) chip needs
      // its label from a state colour, or the text vanishes.
      labelStyle: text.labelLarge?.copyWith(
        color: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected) ? AppColors.onInverse : AppColors.textPrimary,
        ),
      ),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    // Menus: a dark rounded card with a hairline border (see widgets/menus.dart).
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.menu,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    // A small card floating over the bottom of the page: centred and
    // narrow on desktop, inset from the edges on phones.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: _desktop ? 440 : null,
      insetPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      backgroundColor: AppColors.hover,
      elevation: 8,
      contentTextStyle: text.bodyMedium?.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w500),
      actionTextColor: AppColors.accent,
      closeIconColor: AppColors.textSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: AppColors.hover, borderRadius: BorderRadius.circular(4)),
      textStyle: text.bodySmall,
    ),
    dividerTheme: DividerThemeData(color: AppColors.hover, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(iconColor: AppColors.textSecondary),
  );
}
