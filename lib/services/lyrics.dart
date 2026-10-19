import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/track.dart';
import 'ytmusic_web.dart';

/// One timed line of synced lyrics.
class LyricLine {
  const LyricLine(this.time, this.text);

  final Duration time;
  final String text;
}

/// Lyrics for a song: timed lines when available, plain text otherwise.
class Lyrics {
  const Lyrics({this.lines = const [], this.plain, this.instrumental = false, required this.source});

  final List<LyricLine> lines;
  final String? plain;
  final bool instrumental;

  /// Where they came from, shown under the lyrics ("LRCLIB", "Embedded in the file"...).
  final String source;

  bool get synced => lines.isNotEmpty;

  /// Nothing found anywhere.
  bool get isEmpty => lines.isEmpty && plain == null && !instrumental;

  static const none = Lyrics(source: '');

  /// Index of the line being sung at [position], or -1 before the first one.
  int lineAt(Duration position) {
    var lo = 0, hi = lines.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  static final _stamp = RegExp(r'\[(\d+):(\d+(?:[.:]\d+)?)\]');

  /// Parses LRC text. Returns plain lyrics if it has no timestamps.
  static Lyrics parse(String text, {required String source}) {
    final lines = <LyricLine>[];
    var offset = Duration.zero;
    for (final raw in const LineSplitter().convert(text)) {
      final off = RegExp(r'^\[offset:\s*([+-]?\d+)\]', caseSensitive: false).firstMatch(raw.trim());
      if (off != null) {
        // Positive offsets make lyrics appear sooner.
        offset = Duration(milliseconds: -int.parse(off[1]!));
        continue;
      }
      final stamps = _stamp.allMatches(raw).toList();
      if (stamps.isEmpty) continue;
      final words = raw.substring(stamps.last.end).replaceAll(RegExp(r'<\d+:\d+(?:\.\d+)?>'), '').trim();
      for (final s in stamps) {
        final seconds = double.parse(s[2]!.replaceFirst(':', '.'));
        final t = Duration(milliseconds: (int.parse(s[1]!) * 60000 + seconds * 1000).round()) + offset;
        lines.add(LyricLine(t < Duration.zero ? Duration.zero : t, words));
      }
    }
    if (lines.isEmpty) {
      final plain = text.trim();
      return Lyrics(plain: plain.isEmpty ? null : plain, source: source);
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return Lyrics(lines: lines, source: source);
  }

  /// Parses TTML (Apple Music style, as Better Lyrics serves it): one `<p>` per
  /// line, with word or syllable `<span>`s. Background vocals and
  /// translations are left out.
  static Lyrics parseTtml(String ttml, {required String source}) {
    final lines = <LyricLine>[];
    for (final p in XmlDocument.parse(ttml).findAllElements('p')) {
      final begin = _ttmlTime(p.getAttribute('begin'));
      if (begin == null) continue;
      lines.add(LyricLine(begin, _ttmlText(p).replaceAll(RegExp(r'\s+'), ' ').trim()));
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return Lyrics(lines: lines, source: source);
  }

  static String _ttmlText(XmlElement element) {
    final out = StringBuffer();
    for (final node in element.children) {
      if (node is XmlText) {
        out.write(node.value);
      } else if (node is XmlElement) {
        final role = node.attributes.where((a) => a.localName == 'role').map((a) => a.value).firstOrNull;
        if (role != null && role.startsWith('x-')) continue; // x-bg, x-translation, x-roman
        out.write(_ttmlText(node));
      }
    }
    return out.toString();
  }

  /// "13.274", "1:02.500", "00:00:18.234" or "18.2s".
  static Duration? _ttmlTime(String? value) {
    if (value == null) return null;
    final parts = value.trim().replaceFirst(RegExp(r's$'), '').split(':');
    var seconds = 0.0;
    for (final part in parts) {
      final n = double.tryParse(part);
      if (n == null) return null;
      seconds = seconds * 60 + n;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }
}

/// Finds lyrics: a `.lrc` next to the file, then tags, then online. Online,
/// timed lyrics win over plain ones, in this order: YouTube Music (its own
/// Lyrics tab), LRCLIB, then Better Lyrics; plain text in the same order.
abstract final class LyricsService {
  static final _cache = <String, Future<Lyrics>>{};

  /// [Lyrics.none] when there are none; throws when no source could be
  /// reached (that isn't cached, so the next try asks again).
  static Future<Lyrics> forTrack(Track track) {
    final future = _cache[track.id] ??= _find(track);
    future.ignore();
    return future.catchError((Object e) {
      _cache.remove(track.id);
      throw e;
    });
  }

  static Future<Lyrics> _find(Track track) async {
    final path = track.path;
    if (path != null) {
      final local = await Isolate.run(() => _local(path));
      if (local != null && !local.isEmpty) return local;
    }
    final errors = <Object>[];
    Future<Lyrics?> attempt(Future<Lyrics?> Function() source) async {
      try {
        return await source();
      } catch (e) {
        errors.add(e);
        return null;
      }
    }

    // The two main sources at once; Better Lyrics only if neither has them timed.
    final found = [
      ...await Future.wait([attempt(() => _youtube(track)), attempt(() => _lrclib(track))]),
    ];
    if (found.firstWhere(_timed, orElse: () => null) case final timed?) return timed;
    found.add(await attempt(() => _betterLyrics(track)));
    if (found.firstWhere(_timed, orElse: () => null) case final timed?) return timed;
    for (final l in found) {
      if (l == null) continue;
      if (l.plain != null || l.instrumental) return l.synced ? Lyrics(plain: l.plain, source: l.source) : l;
    }
    if (errors.length == found.length) throw errors.first; // nothing could be asked
    return Lyrics.none;
  }

  /// Real timed lyrics: LRCLIB has junk entries with a line or two.
  static bool _timed(Lyrics? l) => l != null && l.lines.where((line) => line.text.isNotEmpty).length >= 4;

  /// The song's own lyrics on YouTube Music (YouTube songs only).
  static Future<Lyrics?> _youtube(Track track) async {
    final id = track.videoId;
    if (id == null) return null;
    final web = YtMusicWeb.anonymous();
    try {
      final l = await web.lyrics(id);
      if (l == null) return null;
      final source = l.source.isEmpty ? 'YouTube Music' : 'YouTube Music (${l.source})';
      if (l.lines.isNotEmpty) {
        return Lyrics(lines: [for (final line in l.lines) LyricLine(line.time, line.text)], source: source);
      }
      return Lyrics(plain: l.plain, source: source);
    } finally {
      web.close();
    }
  }

  /// Better Lyrics (api.betterlyrics.org): word-timed lyrics. Without an API
  /// key it only serves songs it has already cached; a miss is no lyrics.
  static Future<Lyrics?> _betterLyrics(Track track) async {
    final artist = track.artist == Track.unknownArtist ? '' : track.artist;
    if (artist.isEmpty) return null;
    final res = await http.get(
      Uri.https('api.betterlyrics.org', '/getLyrics', {
        's': _cleanTitle(track.title),
        'a': artist,
        'al': ?track.album,
        if (track.duration case final d?) 'd': '${d.inSeconds}',
        'videoId': ?track.videoId,
      }),
      headers: _headers,
    );
    if (res.statusCode != 200) return null; // 401 (not cached), 404, 429...
    final ttml = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['ttml'];
    if (ttml is! String || ttml.trim().isEmpty) return null;
    final l = Lyrics.parseTtml(ttml, source: 'Better Lyrics');
    return l.synced ? l : null;
  }

  static Lyrics? _local(String path) {
    final dot = path.lastIndexOf('.');
    final lrc = File('${dot < 0 ? path : path.substring(0, dot)}.lrc');
    if (lrc.existsSync()) {
      try {
        return Lyrics.parse(lrc.readAsStringSync(), source: 'Lyrics file');
      } catch (_) {}
    }
    try {
      final text = readMetadata(File(path)).lyrics;
      if (text != null && text.trim().isNotEmpty) return Lyrics.parse(text, source: 'Embedded in the file');
    } catch (_) {}
    return null;
  }

  static const _headers = {'User-Agent': 'OpenMusic (https://github.com/Araryarch67/openmusic)'};

  /// "Song (Official Video) [HD]" → "Song".
  static String _cleanTitle(String t) => t
      .replaceAll(
        RegExp(
          r'\s*[\(\[][^\)\]]*(official|video|audio|lyric|visualizer|remaster|hd|4k|mv)[^\)\]]*[\)\]]',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+-\s+topic$', caseSensitive: false), '')
      .trim();

  static Future<Lyrics?> _lrclib(Track track) async {
    final title = _cleanTitle(track.title);
    final artist = track.artist == Track.unknownArtist ? '' : track.artist;
    final seconds = track.duration?.inSeconds;

    // Exact match by title, artist and length first: fast and right most of the time.
    if (artist.isNotEmpty) {
      final res = await http.get(
        Uri.https('lrclib.net', '/api/get', {
          'track_name': title,
          'artist_name': artist,
          'album_name': ?track.album,
          if (seconds != null) 'duration': '$seconds',
        }),
        headers: _headers,
      );
      if (res.statusCode == 200) return _fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
      if (res.statusCode != 404) throw HttpException('lrclib ${res.statusCode}');
    }

    // Otherwise search and pick the closest length, preferring synced lyrics.
    final res = await http.get(
      Uri.https('lrclib.net', '/api/search', {'q': '$artist $title'.trim()}),
      headers: _headers,
    );
    if (res.statusCode != 200) throw HttpException('lrclib ${res.statusCode}');
    final results = (jsonDecode(utf8.decode(res.bodyBytes)) as List).cast<Map<String, dynamic>>();
    if (results.isEmpty) return null;
    double score(Map<String, dynamic> r) {
      final d = (r['duration'] as num?)?.toDouble();
      final off = seconds == null || d == null ? 10.0 : (d - seconds).abs();
      return off + (r['syncedLyrics'] == null ? 15 : 0);
    }

    final best = [...results]..sort((a, b) => score(a).compareTo(score(b)));
    // Way off in length is a different recording (or a different song).
    if (seconds != null && score(best.first) > 30) return null;
    return _fromJson(best.first);
  }

  static Lyrics? _fromJson(Map<String, dynamic> j) {
    if (j['instrumental'] == true) return const Lyrics(instrumental: true, source: 'LRCLIB');
    var plain = (j['plainLyrics'] as String?)?.trim();
    if (plain != null && plain.isEmpty) plain = null;
    final synced = j['syncedLyrics'] as String?;
    if (synced != null && synced.trim().isNotEmpty) {
      final l = Lyrics.parse(synced, source: 'LRCLIB');
      // The plain text too, in case the timed version turns out to be junk.
      if (l.synced) return Lyrics(lines: l.lines, plain: plain, source: 'LRCLIB');
    }
    if (plain == null) return null;
    return Lyrics(plain: plain, source: 'LRCLIB');
  }

  @visibleForTesting
  static void clearCache() => _cache.clear();
}
