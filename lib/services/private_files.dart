import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The app's own folder (`getApplicationSupportDirectory`) and the files in
/// it that only this user may read: the YouTube Music session, the library.
///
/// On Linux and macOS the folder is made `0700` once a run, so other accounts
/// on the machine can't open anything in it (the umask created it `0755`).
/// Files are written aside and renamed over the old ones, so a crash mid-write
/// never leaves half a file. Windows and Android keep the folder private to
/// the user / app already.
abstract final class PrivateFiles {
  static final _locked = <String>{};

  static bool get _posix => Platform.isLinux || Platform.isMacOS;

  /// The support folder, created and locked down. Throws where there is none (widget tests).
  static Future<Directory> dir() async {
    final d = await getApplicationSupportDirectory();
    await d.create(recursive: true);
    // Only the app's own folder (…/dev.openmusic.openmusic), never a shared one a test points it at.
    if (_posix && _locked.add(d.path) && p.basename(d.path).toLowerCase().contains('openmusic')) {
      await _chmod('700', d.path);
    }
    return d;
  }

  static Future<File> file(String name) async => File(p.join((await dir()).path, name));

  /// Writes [contents] to [file] in one step: readers see the old file or the
  /// new one. A [secret] is `0600` before it holds anything, in case the
  /// folder itself couldn't be locked down.
  static Future<void> write(File file, String contents, {bool secret = false}) async {
    final part = File('${file.path}.$pid.part');
    if (secret && _posix) {
      await part.writeAsString('');
      await _chmod('600', part.path);
    }
    await part.writeAsString(contents, flush: true);
    await part.rename(file.path);
  }

  /// [write] for a background isolate (secrets take [write]).
  static void writeSync(File file, String contents) {
    final part = File('${file.path}.$pid.part')..writeAsStringSync(contents, flush: true);
    part.renameSync(file.path);
  }

  static Future<void> _chmod(String mode, String path) async {
    try {
      await Process.run('chmod', [mode, path]);
    } catch (_) {
      // No chmod (a stripped-down system): the folder's own mode stays.
    }
  }
}
