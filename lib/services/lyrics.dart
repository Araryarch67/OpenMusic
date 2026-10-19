import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/track.dart';

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
}

/// Finds lyrics: a `.lrc` next to the file, then tags, then LRCLIB (free, no key).
abstract final class LyricsService {
  static final _cache = <String, Future<Lyrics>>{};

  /// [Lyrics.none] when there are none; throws when LRCLIB can't be reached
  /// (that isn't cached, so the next try asks again).
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
    return await _lrclib(track) ?? Lyrics.none;
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
      .replaceAll(RegExp(r'\s*[\(\[][^\)\]]*(official|video|audio|lyric|visualizer|remaster|hd|4k|mv)[^\)\]]*[\)\]]', caseSensitive: false), '')
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
    final res = await http.get(Uri.https('lrclib.net', '/api/search', {'q': '$artist $title'.trim()}), headers: _headers);
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
    final synced = j['syncedLyrics'] as String?;
    if (synced != null && synced.trim().isNotEmpty) {
      final l = Lyrics.parse(synced, source: 'LRCLIB');
      if (l.synced) return l;
    }
    final plain = (j['plainLyrics'] as String?)?.trim();
    if (plain == null || plain.isEmpty) return null;
    return Lyrics(plain: plain, source: 'LRCLIB');
  }

  @visibleForTesting
  static void clearCache() => _cache.clear();
}
