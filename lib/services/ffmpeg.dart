import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The `ffmpeg` command, for what libmpv can't do: writing tags into MP3 / Ogg
/// files, and converting for AirPlay and TVs. A system one is used when
/// installed; otherwise the official static build is downloaded the first time
/// it's needed (like yt-dlp), checked against its published checksum, and kept
/// in the app's folder.
abstract final class Ffmpeg {
  static String? _path;
  static bool _probed = false;
  static Future<String>? _download;

  /// Called when a download starts, so the user hears why something takes a moment.
  static void Function(String message)? onDownload;

  /// Looks for an installed or already downloaded ffmpeg (no download). Runs once at startup.
  static Future<void> probe() async {
    _probed = true;
    try {
      if ((await Process.run('ffmpeg', ['-hide_banner', '-version'])).exitCode == 0) {
        _path = 'ffmpeg';
        return;
      }
    } catch (_) {
      // Not on PATH.
    }
    final local = await _localFile();
    if (local.existsSync()) _path = local.path;
  }

  /// ffmpeg is here already.
  static bool get installed => _path != null;

  /// ffmpeg is here, or can be fetched on first use.
  static bool get available => installed || _source != null;

  /// The path to run, downloading ffmpeg first if needed.
  static Future<String> executable() async {
    if (!_probed) await probe();
    if (_path case final path?) return path;
    return _download ??= _fetch().then(
      (path) => _path = path,
      onError: (Object e) {
        _download = null; // try again next time
        throw e;
      },
    );
  }

  static Future<File> _localFile() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'bin', Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg'));

  /// Where the official builds live, with how to check them; null where none is offered.
  static ({String url, String checksumUrl, Hash hash, String? fallbackUrl})? get _source {
    if (Platform.isWindows) {
      // gyan.dev, the builds ffmpeg.org links for Windows: the 7z is a third of the zip's size.
      // Windows' own tar opens 7z on recent versions; older ones take the zip.
      return (
        url: 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.7z',
        checksumUrl: 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.7z.sha256',
        hash: sha256,
        fallbackUrl: 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
      );
    }
    if (Platform.isLinux) {
      // John Van Sickle's static builds, linked from ffmpeg.org for Linux.
      final arch = switch (Abi.current()) {
        Abi.linuxX64 => 'amd64',
        Abi.linuxArm64 => 'arm64',
        _ => null,
      };
      if (arch == null) return null;
      final url = 'https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-$arch-static.tar.xz';
      return (url: url, checksumUrl: '$url.md5', hash: md5, fallbackUrl: null);
    }
    return null;
  }

  static Future<String> _fetch() async {
    final source = _source;
    if (source == null) throw StateError('FFmpeg isn\'t installed. Install it to use this.');
    onDownload?.call('Downloading FFmpeg for this, once (about 40 MB)…');
    final target = await _localFile();
    final work = await Directory.systemTemp.createTemp('openmusic-ffmpeg');
    try {
      Future<bool> attempt(String url, {String? checksumUrl}) async {
        final archive = File(p.join(work.path, p.basename(url)));
        await _get(url, archive);
        if (checksumUrl != null) {
          final expected = (await http.get(Uri.parse(checksumUrl))).body.trim().split(RegExp(r'\s+')).first;
          final actual = (await source.hash.bind(archive.openRead()).first).toString();
          if (expected.toLowerCase() != actual) throw StateError('The FFmpeg download was damaged; try again.');
        }
        final out = Directory(p.join(work.path, 'out'))..createSync();
        final r = await Process.run(_tar, ['-xf', archive.path, '-C', out.path]);
        if (r.exitCode != 0) return false;
        final exe = out
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => p.basename(f.path) == p.basename(target.path))
            .firstOrNull;
        if (exe == null) return false;
        await target.parent.create(recursive: true);
        await exe.copy(target.path);
        if (!Platform.isWindows) await Process.run('chmod', ['755', target.path]);
        return true;
      }

      if (!await attempt(source.url, checksumUrl: source.checksumUrl)) {
        final fallback = source.fallbackUrl;
        // The zip has its own checksum file next to it.
        if (fallback == null || !await attempt(fallback, checksumUrl: '$fallback.sha256')) {
          throw StateError('Couldn\'t unpack FFmpeg.');
        }
      }
      final check = await Process.run(target.path, ['-hide_banner', '-version']);
      if (check.exitCode != 0) throw StateError('The downloaded FFmpeg doesn\'t run on this device.');
      debugPrint('FFmpeg: ${(check.stdout as String).split('\n').first}');
      return target.path;
    } finally {
      work.delete(recursive: true).ignore();
    }
  }

  /// Windows' own bsdtar (Git's GNU tar on PATH can't open 7z or zip).
  static String get _tar =>
      Platform.isWindows ? p.join(Platform.environment['WINDIR'] ?? r'C:\Windows', 'System32', 'tar.exe') : 'tar';

  static Future<void> _get(String url, File to) async {
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode != 200) throw HttpException('FFmpeg download failed (${res.statusCode})', uri: Uri.parse(url));
      await res.stream.pipe(to.openWrite());
    } finally {
      client.close();
    }
  }
}
