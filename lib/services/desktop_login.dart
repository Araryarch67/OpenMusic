import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Linux sign-in window (linux/login_helper): Google's own login page in a
/// WebKitGTK window, which hands the YouTube Music session back on stdout.
abstract final class DesktopLogin {
  static const _name = 'openmusic_login';

  /// The helper next to the app binary; null when it was not built (no
  /// webkit2gtk-4.1 at build time) or on other platforms.
  static final String? helperPath = () {
    if (!Platform.isLinux) return null;
    final path = p.join(p.dirname(Platform.resolvedExecutable), _name);
    return File(path).existsSync() ? path : null;
  }();

  static bool get supported => helperPath != null;

  /// Exit code when the user closed the window before finishing.
  static const _closedByUser = 3;

  /// Opens the window and waits. Null when the user closed it before finishing;
  /// throws [DesktopLoginException] when the window failed (crashed, no display...).
  static Future<({String cookies, String visitorData, String authUser})?> run() async {
    final proc = await Process.start(helperPath!, const []);
    final (out, err, code) = await (
      proc.stdout.transform(utf8.decoder).join(),
      proc.stderr.transform(utf8.decoder).join(),
      proc.exitCode,
    ).wait;
    if (code == _closedByUser) return null;
    if (code != 0) {
      final reason = const LineSplitter()
          .convert(err)
          .where((l) => l.trim().isNotEmpty && !l.contains('CRITICAL') && !l.contains('MESA'))
          .lastOrNull;
      debugPrint('Sign-in window exited $code: $reason');
      throw const DesktopLoginException('The sign-in window closed unexpectedly. Try again.');
    }
    final line = const LineSplitter().convert(out).lastWhere((l) => l.startsWith('{'), orElse: () => '');
    if (line.isEmpty) return null;
    final j = jsonDecode(line) as Map<String, dynamic>;
    return (
      cookies: j['cookies'] as String,
      visitorData: j['visitorData'] as String,
      authUser: j['authUser'] as String? ?? '0',
    );
  }
}

class DesktopLoginException implements Exception {
  const DesktopLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}
