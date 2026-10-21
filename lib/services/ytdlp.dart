import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A directly fetchable audio stream, as resolved by yt-dlp.
class ResolvedAudio {
  const ResolvedAudio({
    required this.url,
    required this.formatId,
    required this.ext,
    required this.codec,
    required this.kbps,
    required this.size,
    required this.resolvedAt,
  });

  final Uri url;
  final String formatId;
  final String ext;
  final String codec;
  final int? kbps;
  final int? size;
  final DateTime resolvedAt;

  bool get isOpus => codec.contains('opus');
  String get quality => '${isOpus ? 'Opus' : 'AAC'}${kbps == null ? '' : ' · $kbps kbps'}';
  String get mimeType => ext == 'webm' ? 'audio/webm' : 'audio/mp4';

  /// googlevideo URLs live ~6h; refresh well before that.
  bool get isFresh => DateTime.now().difference(resolvedAt) < const Duration(hours: 4);
}

/// Wraps the yt-dlp CLI, which keeps up with YouTube's anti-download changes
/// (PO tokens, JS challenges) far faster than in-app extractors.
///
/// Desktop only: prefers a yt-dlp on PATH (kept updated by the system package
/// manager), otherwise downloads the official standalone release once into the
/// app's support folder.
abstract final class YtDlp {
  static bool get supported => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  static Future<String?>? _exe;

  /// Browser whose YouTube login yt-dlp reuses (e.g. "firefox"); null = anonymous.
  /// Cookies are read from the browser on each call and never copied to disk.
  static String? cookiesFromBrowser;

  static List<String> get _cookieArgs =>
      cookiesFromBrowser == null ? const [] : ['--cookies-from-browser', cookiesFromBrowser!];

  /// Browsers yt-dlp can read logins from.
  static const browsers = ['firefox', 'chrome', 'chromium', 'brave', 'edge', 'vivaldi', 'opera', 'safari'];

  /// Supported browsers that look installed, best guess first.
  static Future<List<String>> installedBrowsers() async {
    const binaries = {
      'firefox': ['firefox', 'firefox.exe'],
      'chrome': ['google-chrome', 'google-chrome-stable', 'chrome.exe'],
      'chromium': ['chromium', 'chromium-browser'],
      'brave': ['brave', 'brave-browser', 'brave.exe'],
      'edge': ['microsoft-edge', 'microsoft-edge-stable', 'msedge.exe'],
      'vivaldi': ['vivaldi', 'vivaldi-stable'],
      'opera': ['opera'],
    };
    final found = <String>[];
    final lookup = Platform.isWindows ? 'where' : 'which';
    for (final e in binaries.entries) {
      for (final bin in e.value) {
        try {
          if ((await Process.run(lookup, [bin])).exitCode == 0) {
            found.add(e.key);
            break;
          }
        } catch (_) {}
      }
    }
    if (Platform.isMacOS) found.add('safari');
    return found;
  }

  /// Lists a playlist / feed without resolving each video (`--flat-playlist -J`).
  static Future<Map<String, dynamic>> flatPlaylist(String url, {int? limit}) async {
    final exe = await executable();
    if (exe == null) throw StateError('yt-dlp is not available on this device.');
    final r = await Process.run(exe, [
      '--no-warnings',
      ..._cookieArgs,
      '--flat-playlist',
      '-J',
      if (limit != null) ...['--playlist-items', '1:$limit'],
      '--',
      url,
    ], stdoutEncoding: utf8);
    if (r.exitCode != 0) throw StateError(_lastError(r.stderr as String));
    return jsonDecode(r.stdout as String) as Map<String, dynamic>;
  }

  static String _lastError(String stderr) {
    final line = stderr.trim().split('\n').lastWhere((l) => l.isNotEmpty, orElse: () => 'yt-dlp failed');
    return line.replaceFirst(RegExp(r'^ERROR:\s*(\[[^\]]+\]\s*\S+:\s*)?'), '');
  }

  static final _resolved = <String, Future<ResolvedAudio>>{};

  /// Highest-quality original audio: Opus first (best per bit), then AAC.
  /// DRC ("stable volume") variants are re-processed, so skip them. Apple's
  /// AVPlayer can't play Opus-in-WebM, so macOS takes AAC.
  static String get _format => Platform.isMacOS
      ? 'ba[acodec^=mp4a][format_id!*=drc]/ba[ext=m4a]/ba'
      : 'ba[acodec^=opus][format_id!*=drc]/ba[acodec^=mp4a][format_id!*=drc]/ba';

  static String get _releaseAsset => Platform.isWindows
      ? 'yt-dlp.exe'
      : Platform.isMacOS
      ? 'yt-dlp_macos'
      : 'yt-dlp_linux';

  /// Path to a usable yt-dlp, downloading the official binary if none is installed.
  static Future<String?> executable() => _exe ??= () async {
    if (!supported) return null;
    for (final candidate in ['yt-dlp', if (Platform.isWindows) 'yt-dlp.exe']) {
      try {
        final r = await Process.run(candidate, ['--version']);
        if (r.exitCode == 0) return candidate;
      } catch (_) {
        // Not on PATH.
      }
    }
    final local = File(p.join((await getApplicationSupportDirectory()).path, 'bin', _releaseAsset));
    if (!local.existsSync()) {
      await local.parent.create(recursive: true);
      final res = await http.get(Uri.parse('https://github.com/yt-dlp/yt-dlp/releases/latest/download/$_releaseAsset'));
      if (res.statusCode != 200) return null;
      await local.writeAsBytes(res.bodyBytes);
      if (!Platform.isWindows) await Process.run('chmod', ['755', local.path]);
    }
    return local.path;
  }();

  /// Resolves (and caches for a few hours) the best audio stream of a video.
  /// [aac] takes AAC over Opus, for players that can't decode Opus.
  static Future<ResolvedAudio> resolve(String videoId, {bool aac = false}) {
    final cached = _resolved[aac ? 'aac:$videoId' : videoId];
    if (cached != null) {
      return cached.then((r) => r.isFresh ? r : _refresh(videoId, aac));
    }
    return _refresh(videoId, aac);
  }

  static Future<ResolvedAudio> _refresh(String videoId, bool aac) {
    final key = aac ? 'aac:$videoId' : videoId;
    // One retry: YouTube sometimes refuses a burst of lookups, then serves the next one.
    final future = _run(videoId, aac).catchError((Object _) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return _run(videoId, aac);
    });
    _resolved[key] = future;
    // Don't cache failures.
    future.then<void>(
      (_) {},
      onError: (Object _) {
        _resolved.remove(key);
      },
    );
    return future;
  }

  /// Forget a cached URL (e.g. after the server rejected it).
  static void invalidate(String videoId) => _resolved
    ..remove(videoId)
    ..remove('aac:$videoId');

  static Future<ResolvedAudio> _run(String videoId, bool aac) async {
    final exe = await executable();
    if (exe == null) throw StateError('yt-dlp is not available on this device.');
    final r = await Process.run(exe, [
      '--no-warnings',
      '--no-playlist',
      ..._cookieArgs,
      '-f',
      aac ? 'ba[acodec^=mp4a][format_id!*=drc]/ba[ext=m4a]/ba' : _format,
      '-O',
      '%(format_id)s|%(ext)s|%(acodec)s|%(abr)s|%(filesize,filesize_approx)s',
      '-O',
      '%(url)s',
      '--',
      'https://www.youtube.com/watch?v=$videoId',
    ]);
    if (r.exitCode != 0) throw StateError(_lastError(r.stderr as String));
    final lines = (r.stdout as String).trim().split('\n');
    final f = lines.first.split('|');
    final url = Uri.parse(lines.last.trim());
    return ResolvedAudio(
      formatId: f[0],
      ext: f[1],
      codec: f[2],
      kbps: double.tryParse(f[3])?.round(),
      // googlevideo's clen is the exact byte length; yt-dlp may only know an estimate.
      size: int.tryParse(url.queryParameters['clen'] ?? '') ?? int.tryParse(f[4]),
      url: url,
      resolvedAt: DateTime.now(),
    );
  }
}
