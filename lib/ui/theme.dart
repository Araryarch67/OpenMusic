import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Colour tokens for the dark, streaming-app look.
abstract final class AppColors {
  static const background = Color(0xFF000000);
  static const panel = Color(0xFF121212);
  static const elevated = Color(0xFF1C1C1C);
  static const hover = Color(0xFF2A2A2A);
  static const tile = Color(0x14FFFFFF);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA7A7A7);
  static const textMuted = Color(0xFF6E6E6E);
  static const accent = Color(0xFF2EE6C5);
  static const onAccent = Color(0xFF00201B);
}

ThemeData buildAppTheme({String? fontFamily}) {
  final base = ThemeData(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
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
    iconTheme: const IconThemeData(color: AppColors.textSecondary),
    appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0),
    sliderTheme: const SliderThemeData(
      trackHeight: 4,
      activeTrackColor: AppColors.textPrimary,
      inactiveTrackColor: Color(0x4DFFFFFF),
      thumbColor: AppColors.textPrimary,
      overlayColor: Color(0x1FFFFFFF),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 0),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      trackShape: RoundedRectSliderTrackShape(),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.hover,
      selectedColor: AppColors.textPrimary,
      labelStyle: text.labelLarge,
      secondaryLabelStyle: text.labelLarge?.copyWith(color: Colors.black),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.hover,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.textPrimary,
      contentTextStyle: text.bodyMedium?.copyWith(color: Colors.black, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: AppColors.hover, borderRadius: BorderRadius.circular(4)),
      textStyle: text.bodySmall,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.hover, thickness: 1, space: 1),
    listTileTheme: const ListTileThemeData(iconColor: AppColors.textSecondary),
  );
}
