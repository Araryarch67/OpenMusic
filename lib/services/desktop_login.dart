import 'dart:convert';
import 'dart:io';

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

  /// Opens the window and waits. Null when the user closed it before finishing.
  static Future<({String cookies, String visitorData, String authUser})?> run() async {
    final proc = await Process.start(helperPath!, const []);
    final (out, _, code) = await (
      proc.stdout.transform(utf8.decoder).join(),
      proc.stderr.drain<void>(),
      proc.exitCode,
    ).wait;
    if (code != 0) return null;
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
