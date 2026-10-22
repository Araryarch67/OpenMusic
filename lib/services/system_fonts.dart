import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One font family found on this device, with every file (weight, italic) that belongs to it.
class FontFamilyFiles {
  const FontFamilyFiles(this.family, this.files);

  final String family;
  final List<String> files;
}

/// Fonts installed on this device, read from the font folders rather than
/// asked of each OS: the system's and the user's own font folders, and the
/// app's `fonts` folder, where any `.ttf` / `.otf` dropped in shows up.
abstract final class SystemFonts {
  /// Where the app looks besides the OS folders: `<app support>/fonts`.
  static Future<Directory> appFontsDir() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'fonts'));

  static List<String> get _osDirs {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    if (Platform.isWindows) {
      return [
        p.join(env['WINDIR'] ?? r'C:\Windows', 'Fonts'),
        if (env['LOCALAPPDATA'] case final local?) p.join(local, 'Microsoft', 'Windows', 'Fonts'),
      ];
    }
    if (Platform.isMacOS) {
      return ['/System/Library/Fonts', '/Library/Fonts', p.join(home, 'Library', 'Fonts')];
    }
    final data = (env['XDG_DATA_HOME'] ?? '').isNotEmpty ? env['XDG_DATA_HOME']! : p.join(home, '.local', 'share');
    return ['/usr/share/fonts', '/usr/local/share/fonts', p.join(data, 'fonts'), p.join(home, '.fonts')];
  }

  /// Every family found, sorted by name. Reads only each file's name table, in another isolate.
  static Future<List<FontFamilyFiles>> scan() async {
    final dirs = [..._osDirs, (await appFontsDir()).path];
    return Isolate.run(() => _scan(dirs));
  }

  static List<FontFamilyFiles> _scan(List<String> dirs) {
    final byFamily = <String, List<String>>{};
    for (final dir in dirs) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      try {
        for (final f in d.listSync(recursive: true, followLinks: false)) {
          if (f is! File) continue;
          final ext = p.extension(f.path).toLowerCase();
          if (ext != '.ttf' && ext != '.otf') continue;
          final family = familyOf(f.path);
          if (family == null || family.startsWith('.')) continue;
          byFamily.putIfAbsent(family, () => []).add(f.path);
        }
      } catch (_) {
        // A folder we may not read.
      }
    }
    final out = [for (final e in byFamily.entries) FontFamilyFiles(e.key, e.value)];
    out.sort((a, b) => a.family.toLowerCase().compareTo(b.family.toLowerCase()));
    return out;
  }

  /// The family name stored in a TrueType / OpenType file (its `name` table):
  /// the typographic family (16) when there is one, else the family (1).
  static String? familyOf(String path) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      final head = f.readSync(12);
      if (head.length < 12) return null;
      final numTables = ByteData.sublistView(head).getUint16(4);
      final dir = ByteData.sublistView(f.readSync(numTables * 16));
      for (var i = 0; i + 16 <= dir.lengthInBytes; i += 16) {
        if (String.fromCharCodes(dir.buffer.asUint8List(dir.offsetInBytes + i, 4)) != 'name') continue;
        final offset = dir.getUint32(i + 8);
        final length = dir.getUint32(i + 12);
        f.setPositionSync(offset);
        return _familyFromNameTable(ByteData.sublistView(f.readSync(length)));
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      f?.closeSync();
    }
  }

  static String? _familyFromNameTable(ByteData t) {
    if (t.lengthInBytes < 6) return null;
    final count = t.getUint16(2);
    final strings = t.getUint16(4);
    String? best;
    var bestRank = 99;
    for (var i = 0; i < count; i++) {
      final at = 6 + i * 12;
      if (at + 12 > t.lengthInBytes) break;
      final platform = t.getUint16(at);
      final language = t.getUint16(at + 4);
      final nameId = t.getUint16(at + 6);
      final length = t.getUint16(at + 8);
      final offset = strings + t.getUint16(at + 10);
      if (nameId != 1 && nameId != 16) continue;
      if (offset + length > t.lengthInBytes) continue;
      final bytes = t.buffer.asUint8List(t.offsetInBytes + offset, length);
      final String value;
      if (platform == 3 || platform == 0) {
        // UTF-16BE.
        value = String.fromCharCodes([for (var j = 0; j + 1 < length; j += 2) bytes[j] << 8 | bytes[j + 1]]);
      } else if (platform == 1) {
        value = latin1.decode(bytes, allowInvalid: true);
      } else {
        continue;
      }
      // Typographic family first, then English (Windows 0x409 / Mac 0), then anything.
      final english = (platform == 3 && language == 0x409) || (platform == 1 && language == 0);
      final rank = (nameId == 16 ? 0 : 2) + (english ? 0 : 1);
      if (rank < bestRank && value.trim().isNotEmpty) {
        best = value.trim();
        bestRank = rank;
      }
    }
    return best;
  }

  /// Loads [files] under [family] so the app can draw with it. False when none could be read.
  static Future<bool> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    var any = false;
    for (final path in files) {
      final file = File(path);
      if (!file.existsSync()) continue;
      loader.addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
      any = true;
    }
    if (!any) return false;
    await loader.load();
    return true;
  }
}
