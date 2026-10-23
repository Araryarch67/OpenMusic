import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
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
/// Lyrics tab), LRCLIB, Better Lyrics, then NetEase Cloud Music; plain text
/// in the same order, and lyrics.ovh when no one else has any.
abstract final class LyricsService {
  static final _cache = <String, Future<Lyrics>>{};

  /// [Lyrics.none] when there are none; throws when no source could be
  /// reached (that isn't cached, so the next try asks again).
  static Future<Lyrics> forTrack(Track track) {
    final cached = _cache.remove(track.id);
    final future =
        _cache[track.id] = // newest last
            cached ??
            _find(track).then((r) {
              // A source that couldn't be asked (offline, rate limited) may have them:
              // "none" isn't remembered then, so the next look asks again.
              if (r.missed) _cache.remove(track.id);
              return r.lyrics;
            });
    // A long session plays thousands of songs: keep the lyrics of the last few dozen.
    while (_cache.length > 48) {
      _cache.remove(_cache.keys.first);
    }
    future.ignore();
    return future.catchError((Object e) {
      _cache.remove(track.id);
      throw e;
    });
  }

  static Future<({Lyrics lyrics, bool missed})> _find(Track track) async {
    final path = track.path;
    if (path != null) {
      final local = await Isolate.run(() => _local(path));
      if (local != null && !local.isEmpty) return (lyrics: local, missed: false);
    }
    final errors = <Object>[];
    var asked = 0;
    Future<Lyrics?> attempt(Future<Lyrics?> Function() source) async {
      asked++;
      try {
        return await source();
      } catch (e) {
        debugPrint('Lyrics source failed: $e');
        errors.add(e);
        return null;
      }
    }

    final found = <Lyrics?>[];
    Lyrics? timed() => found.firstWhere(_timed, orElse: () => null);

    // The two main sources at once; the next two only if neither has them timed.
    Future<Lyrics?> search(Track t) async {
      found.addAll(await Future.wait([attempt(() => _youtube(t)), attempt(() => _lrclib(t))]));
      if (timed() case final l?) return l;
      found.addAll(await Future.wait([attempt(() => _betterLyrics(t)), attempt(() => netease(t))]));
      return timed();
    }

    if (await search(track) case final l?) return (lyrics: l, missed: false);

    // Another upload of the same song (a fan's video, a lyric video, the music
    // video of an album track) has no Lyrics tab of its own, and its title and
    // uploader don't match the lyrics sites: ask again as the song YouTube
    // Music's catalogue has.
    Track? same;
    if (track.isRemote) {
      try {
        final match = await _catalogueSong(track);
        if (match != null) {
          same = match.song;
          // Timed lines only fit the same recording; another one gets the words alone.
          if (await search(match.song) case final l?) {
            return (lyrics: match.sameLength ? l : _unsynced(l), missed: false);
          }
        }
      } catch (e) {
        debugPrint('Lyrics: no catalogue song: $e');
        errors.add(e);
      }
    }

    Lyrics? plain() {
      for (final l in found) {
        if (l == null) continue;
        if (l.plain != null || l.instrumental) return l.synced ? Lyrics(plain: l.plain, source: l.source) : l;
      }
      return null;
    }

    if (plain() case final l?) return (lyrics: l, missed: false);
    found.add(await attempt(() => lyricsOvh(same ?? track)));
    if (plain() case final l?) return (lyrics: l, missed: false);
    if (errors.length >= asked) throw errors.first; // nothing could be asked
    return (lyrics: Lyrics.none, missed: errors.isNotEmpty);
  }

  /// Real timed lyrics. LRCLIB has junk entries with a line or two; from the
  /// others a song with only a few words (a beatbox track) is still lyrics.
  static bool _timed(Lyrics? l) =>
      l != null && l.lines.where((line) => line.text.isNotEmpty).length >= (l.source == 'LRCLIB' ? 4 : 1);

  /// Lines of another recording, as words without times.
  static Lyrics _unsynced(Lyrics l) => l.plain != null
      ? Lyrics(plain: l.plain, source: l.source)
      : Lyrics(plain: [for (final line in l.lines) line.text].join('\n').trim(), source: l.source);

  /// The song YouTube Music's catalogue has under the upload's words: its
  /// title has to be in the upload's title, and the artist named there or the
  /// length the same. [sameLength]: within a few seconds, so timed lines fit.
  static Future<({Track song, bool sameLength})?> _catalogueSong(Track upload) async {
    final title = _cleanTitle(upload.title);
    final uploader = upload.artist == Track.unknownArtist ? '' : upload.artist;
    final words = _norm('$title $uploader');
    final web = YtMusicWeb.anonymous();
    try {
      // The upload's own words first, then only the song's part of them
      // ("Song - Artist Karaoke Lower Key" → "Song - Artist").
      for (final query in {'$title $uploader'.trim(), _core(upload.title)}) {
        if (query.isEmpty) continue;
        for (final hit in (await web.searchSongs(query)).take(8)) {
          if (hit.videoId == upload.videoId) continue; // asked already
          final name = _norm(_cleanTitle(hit.title));
          if (name.isEmpty || !_norm(title).contains(name)) continue;
          final artist = _norm(hit.artist.split(', ').first);
          final named = artist.isNotEmpty && words.contains(artist);
          final a = upload.duration, b = hit.duration;
          final sameLength = a != null && b != null && (a - b).abs() <= const Duration(seconds: 3);
          if (!named && !sameLength) continue;
          final song = Track.youtube(
            videoId: hit.videoId,
            title: hit.title,
            artist: hit.artist.isEmpty ? Track.unknownArtist : hit.artist,
            duration: hit.duration,
          );
          return (song: song, sameLength: sameLength);
        }
      }
      return null;
    } finally {
      web.close();
    }
  }

  /// Words in a video's title that say it's a version of the song, and all after them.
  static final _versionWords = RegExp(
    r'[\s|:,–—-]*\b(karaoke|cover|covered|live|remix|lyrics?|lirik|instrumental|reaction|acoustic|versi|version|'
    r'lower key|female key|male key|nada rendah|nada tinggi|slowed|reverb|sped up|nightcore|tiktok)\b.*$',
    caseSensitive: false,
  );

  /// The song's part of a video title: "Tulus - Hati Hati Di Jalan Karaoke Lower Key" → "Tulus - Hati Hati Di Jalan".
  static String _core(String title) => _cleanTitle(title).replaceFirst(_versionWords, '').replaceAll('|', ' ').trim();

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

  /// The user's own Better Lyrics API key, if they have one: it lets Better
  /// Lyrics fetch songs it hasn't cached yet. Optional; keys aren't handed out
  /// to everyone.
  static String? betterLyricsKey;

  static Future<void> loadBetterLyricsKey() async {
    betterLyricsKey = (await SharedPreferences.getInstance()).getString('lyrics.betterLyricsKey');
  }

  /// Saves [key] (null removes it) after Better Lyrics accepts it. Returns
  /// false when Better Lyrics says the key isn't valid; throws when it can't
  /// be reached.
  static Future<bool> setBetterLyricsKey(String? key, {http.Client? client}) async {
    key = key?.trim();
    if (key != null && key.isEmpty) key = null;
    if (key != null) {
      // Better Lyrics only checks the key on a cache miss (a cached song is
      // served to anyone), so ask for a song that can't be cached.
      final res = await (client ?? _http).get(
        Uri.https('api.betterlyrics.org', '/getLyrics', {
          's': 'openmusic key check ${DateTime.now().microsecondsSinceEpoch}',
          'a': 'openmusic',
          'd': '1',
        }),
        headers: {..._headers, 'X-API-Key': key},
      );
      final mode = res.headers['x-auth-mode'];
      if (mode == 'invalid' || res.statusCode == 401 || res.statusCode == 403) return false;
      if (mode == null && res.statusCode >= 500) throw HttpException('Better Lyrics ${res.statusCode}');
    }
    final prefs = await SharedPreferences.getInstance();
    key == null ? await prefs.remove('lyrics.betterLyricsKey') : await prefs.setString('lyrics.betterLyricsKey', key);
    betterLyricsKey = key;
    // Songs that came up empty may have lyrics now.
    _cache.clear();
    return true;
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
      headers: {..._headers, 'X-API-Key': ?betterLyricsKey},
    );
    if (res.statusCode != 200) return null; // 401 (not cached), 404, 429...
    final ttml = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['ttml'];
    if (ttml is! String || ttml.trim().isEmpty) return null;
    final l = Lyrics.parseTtml(ttml, source: 'Better Lyrics');
    return l.synced ? l : null;
  }

  static final _http = http.Client();

  /// Lowercase letters and digits only, so "Hati-Hati di Jalan" matches "hati hati di jalan".
  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  /// NetEase's songwriter and producer credits, given as the first timed lines.
  static final _credit = RegExp(r'^\s*(\[[^\]]*\])*\s*(作词|作曲|编曲|制作人|监制|混音|录音|和声|母带|词|曲)\s*[:：]');

  /// NetEase Cloud Music: a large catalogue of timed lyrics, including many
  /// songs LRCLIB lacks. Free and keyless; the same endpoints open-source
  /// players (LyricsX, YesPlayMusic) use.
  @visibleForTesting
  static Future<Lyrics?> netease(Track track, {http.Client? client}) async {
    final artist = track.artist == Track.unknownArtist ? '' : track.artist;
    if (artist.isEmpty) return null;
    final c = client ?? _http;
    final title = _cleanTitle(track.title);
    // Without the desktop client's cookie many songs come back with empty lyrics.
    const headers = {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://music.163.com', 'Cookie': 'os=pc'};
    final res = await c.get(
      Uri.https('music.163.com', '/api/cloudsearch/pc', {'s': '$artist $title', 'type': '1', 'limit': '10'}),
      headers: headers,
    );
    if (res.statusCode != 200) throw HttpException('NetEase ${res.statusCode}');
    final result = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['result'];
    final songs = ((result is Map ? result['songs'] : null) as List? ?? const []).cast<Map<String, dynamic>>();
    final want = _norm(title), who = _norm(artist), seconds = track.duration?.inSeconds;
    // Same title, a shared artist and the same length: covers and remixes share titles.
    // The same song is often listed more than once, not every copy with lyrics.
    final matches = songs.where((s) {
      final artists = [for (final a in (s['ar'] as List? ?? const [])) _norm((a as Map)['name'] as String? ?? '')];
      final ms = (s['dt'] as num?)?.toInt();
      return _norm(_cleanTitle(s['name'] as String? ?? '')) == want &&
          artists.any((a) => a.isNotEmpty && (who.contains(a) || a.contains(who))) &&
          (seconds == null || ms == null || (ms / 1000 - seconds).abs() <= 3);
    });
    for (final song in matches.take(3)) {
      final lr = await c.get(
        Uri.https('music.163.com', '/api/song/lyric', {'id': '${song['id']}', 'lv': '-1'}),
        headers: headers,
      );
      if (lr.statusCode != 200) throw HttpException('NetEase ${lr.statusCode}');
      final text = ((jsonDecode(utf8.decode(lr.bodyBytes)) as Map<String, dynamic>)['lrc'] as Map?)?['lyric'];
      if (text is! String || text.trim().isEmpty) continue;
      if (text.contains('纯音乐')) return const Lyrics(instrumental: true, source: 'NetEase Cloud Music');
      final l = Lyrics.parse(
        text.split('\n').where((line) => !_credit.hasMatch(line)).join('\n'),
        source: 'NetEase Cloud Music',
      );
      if (!l.isEmpty) return l;
    }
    return null;
  }

  /// lyrics.ovh (open source): plain text only, so it is asked last.
  @visibleForTesting
  static Future<Lyrics?> lyricsOvh(Track track, {http.Client? client}) async {
    final artist = track.artist == Track.unknownArtist ? '' : track.artist;
    if (artist.isEmpty) return null;
    final res = await (client ?? _http)
        .get(
          Uri(scheme: 'https', host: 'api.lyrics.ovh', pathSegments: ['v1', artist, _cleanTitle(track.title)]),
          headers: _headers,
        )
        // It is often slow; a lyrics view shouldn't wait on it for long.
        .timeout(const Duration(seconds: 8));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) throw HttpException('lyrics.ovh ${res.statusCode}');
    final text = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['lyrics'];
    if (text is! String) return null;
    // Some entries start with a French "Paroles de la chanson … par …" heading.
    final plain = text.replaceFirst(RegExp(r'^Paroles de la chanson[^\n]*\n'), '').replaceAll('\r', '').trim();
    return plain.isEmpty ? null : Lyrics(plain: plain, source: 'lyrics.ovh');
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
}
