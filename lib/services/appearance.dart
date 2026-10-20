import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Accent colours to pick from in Settings › Appearance.
enum AccentChoice {
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

  AccentChoice accent = AccentChoice.teal;

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

  double textScale = 1;

  /// Whether the window itself can be see-through. Linux only so far; the
  /// runner gives the window an alpha channel.
  static bool get hasWindowOpacity => Platform.isLinux;

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      accent = AccentChoice.values.asNameMap()[j['accent']] ?? accent;
      coverColors = j['coverColors'] as bool? ?? coverColors;
      nowPlaying = NowPlayingBackground.values.asNameMap()[j['nowPlaying']] ?? nowPlaying;
      glass = j['glass'] as bool? ?? glass;
      blur = (j['blur'] as num?)?.toDouble().clamp(4, 48) ?? blur;
      windowOpacity = hasWindowOpacity ? (j['windowOpacity'] as num?)?.toDouble().clamp(0.5, 1) ?? 1 : 1;
      textScale = (j['textScale'] as num?)?.toDouble().clamp(0.85, 1.3) ?? textScale;
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
        'accent': accent.name,
        'coverColors': coverColors,
        'nowPlaying': nowPlaying.name,
        'glass': glass,
        'blur': blur,
        'windowOpacity': windowOpacity,
        'textScale': textScale,
      }),
    );
  }

  Future<void> setAccent(AccentChoice v) => _set(() => accent = v);
  Future<void> setCoverColors(bool v) => _set(() => coverColors = v);
  Future<void> setNowPlaying(NowPlayingBackground v) => _set(() => nowPlaying = v);
  Future<void> setGlass(bool v) => _set(() => glass = v);
  Future<void> setBlur(double v) => _set(() => blur = v);
  Future<void> setWindowOpacity(double v) => _set(() => windowOpacity = v);
  Future<void> setTextScale(double v) => _set(() => textScale = v);
}
