import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'system_fonts.dart';

/// Every colour of one theme: surfaces from the window down to hover, text, and the theme's own accent.
class AppPalette {
  const AppPalette({
    required this.background,
    required this.panel,
    required this.elevated,
    required this.hover,
    required this.menu,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.onAccent,
    this.light = false,
  });

  /// The window, behind the panels.
  final Color background;
  final Color panel;

  /// Cards and settings groups.
  final Color elevated;
  final Color hover;
  final Color menu;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color onAccent;

  /// Dark text on light surfaces.
  final bool light;
}

/// The colour schemes in Settings › Appearance, from their authors' palettes.
enum ThemeChoice {
  standard(
    'Default',
    AppPalette(
      background: Color(0xFF000000),
      panel: Color(0xFF121212),
      elevated: Color(0xFF1C1C1C),
      hover: Color(0xFF2A2A2A),
      menu: Color(0xFF242424),
      textPrimary: Color(0xFFFFFFFF),
      textSecondary: Color(0xFFA7A7A7),
      textMuted: Color(0xFF6E6E6E),
      accent: Color(0xFF2EE6C5),
      onAccent: Color(0xFF00201B),
    ),
  ),
  monochrome(
    'Monochrome',
    AppPalette(
      background: Color(0xFF000000),
      panel: Color(0xFF0E0E0E),
      elevated: Color(0xFF191919),
      hover: Color(0xFF262626),
      menu: Color(0xFF1F1F1F),
      textPrimary: Color(0xFFF2F2F2),
      textSecondary: Color(0xFF9E9E9E),
      textMuted: Color(0xFF616161),
      accent: Color(0xFFF2F2F2),
      onAccent: Color(0xFF000000),
    ),
  ),
  catppuccinMocha(
    'Catppuccin Mocha',
    AppPalette(
      background: Color(0xFF11111B), // crust
      panel: Color(0xFF1E1E2E), // base
      elevated: Color(0xFF313244), // surface0
      hover: Color(0xFF45475A), // surface1
      menu: Color(0xFF181825), // mantle
      textPrimary: Color(0xFFCDD6F4), // text
      textSecondary: Color(0xFFA6ADC8), // subtext0
      textMuted: Color(0xFF7F849C), // overlay1
      accent: Color(0xFFCBA6F7), // mauve
      onAccent: Color(0xFF11111B),
    ),
  ),
  catppuccinMacchiato(
    'Catppuccin Macchiato',
    AppPalette(
      background: Color(0xFF181926), // crust
      panel: Color(0xFF24273A), // base
      elevated: Color(0xFF363A4F), // surface0
      hover: Color(0xFF494D64), // surface1
      menu: Color(0xFF1E2030), // mantle
      textPrimary: Color(0xFFCAD3F5), // text
      textSecondary: Color(0xFFA5ADCB), // subtext0
      textMuted: Color(0xFF8087A2), // overlay1
      accent: Color(0xFFC6A0F6), // mauve
      onAccent: Color(0xFF181926),
    ),
  ),
  catppuccinFrappe(
    'Catppuccin Frappé',
    AppPalette(
      background: Color(0xFF232634), // crust
      panel: Color(0xFF303446), // base
      elevated: Color(0xFF414559), // surface0
      hover: Color(0xFF51576D), // surface1
      menu: Color(0xFF292C3C), // mantle
      textPrimary: Color(0xFFC6D0F5), // text
      textSecondary: Color(0xFFA5ADCE), // subtext0
      textMuted: Color(0xFF838BA7), // overlay1
      accent: Color(0xFFCA9EE6), // mauve
      onAccent: Color(0xFF232634),
    ),
  ),
  catppuccinLatte(
    'Catppuccin Latte',
    AppPalette(
      background: Color(0xFFDCE0E8), // crust
      panel: Color(0xFFEFF1F5), // base
      elevated: Color(0xFFE6E9EF), // mantle
      hover: Color(0xFFCCD0DA), // surface0
      menu: Color(0xFFE6E9EF),
      textPrimary: Color(0xFF4C4F69), // text
      textSecondary: Color(0xFF6C6F85), // subtext0
      textMuted: Color(0xFF8C8FA1), // overlay1
      accent: Color(0xFF8839EF), // mauve
      onAccent: Color(0xFFEFF1F5),
      light: true,
    ),
  ),
  everblush(
    'Everblush',
    AppPalette(
      background: Color(0xFF0F1517),
      panel: Color(0xFF141B1E), // background
      elevated: Color(0xFF1E2528),
      hover: Color(0xFF2D3437), // color8
      menu: Color(0xFF232A2D), // color0
      textPrimary: Color(0xFFDADADA), // foreground
      textSecondary: Color(0xFFB3B9B8), // color7
      textMuted: Color(0xFF6B7275),
      accent: Color(0xFF8CCF7E), // green
      onAccent: Color(0xFF141B1E),
    ),
  ),
  everforestDark(
    'Everforest Dark',
    AppPalette(
      background: Color(0xFF232A2E), // bg_dim
      panel: Color(0xFF2D353B), // bg0
      elevated: Color(0xFF343F44), // bg1
      hover: Color(0xFF475258), // bg3
      menu: Color(0xFF3D484D), // bg2
      textPrimary: Color(0xFFD3C6AA), // fg
      textSecondary: Color(0xFF9DA9A0), // grey2
      textMuted: Color(0xFF7A8478), // grey0
      accent: Color(0xFFA7C080), // green
      onAccent: Color(0xFF2D353B),
    ),
  ),
  everforestLight(
    'Everforest Light',
    AppPalette(
      background: Color(0xFFEFEBD4), // bg_dim
      panel: Color(0xFFFDF6E3), // bg0
      elevated: Color(0xFFF4F0D9), // bg1
      hover: Color(0xFFE6E2CC), // bg3
      menu: Color(0xFFF4F0D9),
      textPrimary: Color(0xFF5C6A72), // fg
      textSecondary: Color(0xFF829181), // grey2
      textMuted: Color(0xFFA6B0A0), // grey0
      accent: Color(0xFF8DA101), // green
      onAccent: Color(0xFFFDF6E3),
      light: true,
    ),
  ),
  nord(
    'Nord',
    AppPalette(
      background: Color(0xFF242933),
      panel: Color(0xFF2E3440), // nord0
      elevated: Color(0xFF3B4252), // nord1
      hover: Color(0xFF4C566A), // nord3
      menu: Color(0xFF434C5E), // nord2
      textPrimary: Color(0xFFECEFF4), // nord6
      textSecondary: Color(0xFFD8DEE9), // nord4
      textMuted: Color(0xFF8790A3),
      accent: Color(0xFF88C0D0), // nord8
      onAccent: Color(0xFF2E3440),
    ),
  ),
  gruvbox(
    'Gruvbox',
    AppPalette(
      background: Color(0xFF1D2021), // bg0_h
      panel: Color(0xFF282828), // bg0
      elevated: Color(0xFF32302F), // bg0_s
      hover: Color(0xFF504945), // bg2
      menu: Color(0xFF3C3836), // bg1
      textPrimary: Color(0xFFEBDBB2), // fg
      textSecondary: Color(0xFFBDAE93), // fg3
      textMuted: Color(0xFF928374), // gray
      accent: Color(0xFFFE8019), // orange
      onAccent: Color(0xFF282828),
    ),
  ),
  tokyoNight(
    'Tokyo Night',
    AppPalette(
      background: Color(0xFF16161E),
      panel: Color(0xFF1A1B26), // bg
      elevated: Color(0xFF24283B), // bg_highlight
      hover: Color(0xFF292E42),
      menu: Color(0xFF1F2335),
      textPrimary: Color(0xFFC0CAF5), // fg
      textSecondary: Color(0xFFA9B1D6), // fg_dark
      textMuted: Color(0xFF565F89), // comment
      accent: Color(0xFF7AA2F7), // blue
      onAccent: Color(0xFF16161E),
    ),
  ),
  dracula(
    'Dracula',
    AppPalette(
      background: Color(0xFF191A21),
      panel: Color(0xFF282A36), // background
      elevated: Color(0xFF343746),
      hover: Color(0xFF44475A), // current line
      menu: Color(0xFF21222C),
      textPrimary: Color(0xFFF8F8F2), // foreground
      textSecondary: Color(0xFFBFC2D3),
      textMuted: Color(0xFF6272A4), // comment
      accent: Color(0xFFBD93F9), // purple
      onAccent: Color(0xFF282A36),
    ),
  ),
  rosePine(
    'Rosé Pine',
    AppPalette(
      background: Color(0xFF12101A),
      panel: Color(0xFF191724), // base
      elevated: Color(0xFF1F1D2E), // surface
      hover: Color(0xFF26233A), // overlay
      menu: Color(0xFF1F1D2E),
      textPrimary: Color(0xFFE0DEF4), // text
      textSecondary: Color(0xFF908CAA), // subtle
      textMuted: Color(0xFF6E6A86), // muted
      accent: Color(0xFFEBBCBA), // rose
      onAccent: Color(0xFF191724),
    ),
  );

  const ThemeChoice(this.label, this.palette);
  final String label;
  final AppPalette palette;
}

/// Accent colours to pick from in Settings › Appearance.
enum AccentChoice {
  /// The theme's own accent (mauve for Catppuccin, green for Everforest...).
  theme('Theme', Color(0x00000000), Color(0x00000000)),
  teal('Teal', Color(0xFF2EE6C5), Color(0xFF00201B)),
  green('Green', Color(0xFF1ED760), Color(0xFF00210B)),
  blue('Blue', Color(0xFF4C9AFF), Color(0xFF001B3D)),
  violet('Violet', Color(0xFFB18CFF), Color(0xFF1E0D45)),
  pink('Pink', Color(0xFFFF6FAE), Color(0xFF3D0020)),
  orange('Orange', Color(0xFFFF9F43), Color(0xFF3A1A00)),
  white('White', Color(0xFFFFFFFF), Color(0xFF000000));

  const AccentChoice(this.label, this.color, this.onColor);
  final String label;
  final Color color;
  final Color onColor;
}

/// What fills the phone's Now Playing page behind the cover.
enum NowPlayingBackground {
  color('Cover colour'),
  blurredCover('Blurred cover'),
  black('Black');

  const NowPlayingBackground(this.label);
  final String label;
}

/// How the app looks: accent, cover colours, frosted glass, window
/// transparency and text size. One instance for the whole app ([instance]),
/// loaded before the first frame so nothing flashes.
class Appearance extends ChangeNotifier {
  Appearance._();

  static final instance = Appearance._();

  static const _key = 'appearance.v1';

  ThemeChoice theme = ThemeChoice.standard;

  AccentChoice accent = AccentChoice.theme;

  AppPalette get palette => theme.palette;

  /// The accent in use: the theme's own, or the one picked.
  Color get accentColor => accent == AccentChoice.theme ? palette.accent : accent.color;
  Color get onAccentColor => accent == AccentChoice.theme ? palette.onAccent : accent.onColor;

  /// Tint pages and the player with the colour of the cover art.
  bool coverColors = true;

  NowPlayingBackground nowPlaying = NowPlayingBackground.color;

  /// Frosted, see-through player bar, mini player and tab bar.
  bool glass = false;

  /// Blur radius of the frosted panels.
  double blur = 24;

  /// How opaque the window's background is (1 = solid). Below 1 the desktop
  /// shows through, and a compositor that blurs windows (Hyprland, KDE) blurs it.
  double windowOpacity = 1;

  /// Body text size in pixels (Material's default is 14); everything else scales with it.
  double textSize = defaultTextSize;

  static const defaultTextSize = 14.0;
  static const minTextSize = 11.0;
  static const maxTextSize = 20.0;

  double get textScale => textSize / defaultTextSize;

  /// A font from the device's font folders ([SystemFonts]); null is OpenMusic's own (Figtree).
  String? fontFamily;
  List<String> _fontFiles = const [];

  /// Whether the window itself can be see-through. Linux only so far; the
  /// runner gives the window an alpha channel.
  static bool get hasWindowOpacity => Platform.isLinux;

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      theme = ThemeChoice.values.asNameMap()[j['theme']] ?? theme;
      accent = AccentChoice.values.asNameMap()[j['accent']] ?? accent;
      coverColors = j['coverColors'] as bool? ?? coverColors;
      nowPlaying = NowPlayingBackground.values.asNameMap()[j['nowPlaying']] ?? nowPlaying;
      glass = j['glass'] as bool? ?? glass;
      blur = (j['blur'] as num?)?.toDouble().clamp(4, 48) ?? blur;
      windowOpacity = hasWindowOpacity ? (j['windowOpacity'] as num?)?.toDouble().clamp(0.5, 1) ?? 1 : 1;
      final size =
          (j['textSize'] as num?)?.toDouble() ??
          // Saved by older versions as a scale (0.9 "Small" ... 1.3 "Largest").
          ((j['textScale'] as num?)?.toDouble() ?? 1) * defaultTextSize;
      textSize = size.roundToDouble().clamp(minTextSize, maxTextSize);
      final family = j['fontFamily'] as String?;
      final files = (j['fontFiles'] as List?)?.cast<String>() ?? const [];
      // The saved files, not a rescan: fast, and a font that's gone falls back to the default.
      if (family != null && await SystemFonts.load(family, files)) {
        fontFamily = family;
        _fontFiles = files;
      }
    } catch (e) {
      debugPrint('Appearance settings unreadable, using defaults: $e');
    }
  }

  Future<void> _set(VoidCallback change) async {
    change();
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode({
        'theme': theme.name,
        'accent': accent.name,
        'coverColors': coverColors,
        'nowPlaying': nowPlaying.name,
        'glass': glass,
        'blur': blur,
        'windowOpacity': windowOpacity,
        'textSize': textSize,
        'fontFamily': fontFamily,
        'fontFiles': _fontFiles,
      }),
    );
  }

  /// A new theme brings its own accent; another can be picked after.
  Future<void> setTheme(ThemeChoice v) => _set(() {
    theme = v;
    accent = AccentChoice.theme;
  });
  Future<void> setAccent(AccentChoice v) => _set(() => accent = v);
  Future<void> setCoverColors(bool v) => _set(() => coverColors = v);
  Future<void> setNowPlaying(NowPlayingBackground v) => _set(() => nowPlaying = v);
  Future<void> setGlass(bool v) => _set(() => glass = v);
  Future<void> setBlur(double v) => _set(() => blur = v);
  Future<void> setWindowOpacity(double v) => _set(() => windowOpacity = v);

  /// Draws the app in [font] (null: back to OpenMusic's own). False when its files couldn't be loaded.
  Future<bool> setFont(FontFamilyFiles? font) async {
    if (font != null && !await SystemFonts.load(font.family, font.files)) return false;
    await _set(() {
      fontFamily = font?.family;
      _fontFiles = font?.files ?? const [];
    });
    return true;
  }

  Future<void> setTextSize(double v) => _set(() => textSize = v.roundToDouble().clamp(minTextSize, maxTextSize));
}
