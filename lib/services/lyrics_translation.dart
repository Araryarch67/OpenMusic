import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// What can be shown under one lyric line.
@immutable
class LineExtras {
  const LineExtras({this.romanized, this.translation});

  /// The line in Latin letters ("kyō mo mata hajimaru"), only for lines in
  /// another script.
  final String? romanized;

  /// The line in the reader's language, only when it is in another one.
  final String? translation;

  static const none = LineExtras();
}

/// Pronunciation and translation of lyrics, the way the Better Lyrics extension
/// does it: Google Translate's free endpoint returns both in one request, and
/// Better Lyrics' own translation service stands in when that fails.
abstract final class LyricsTranslation {
  /// Whether to show each line's pronunciation / translation. Saved.
  static final romanize = ValueNotifier(false);
  static final translate = ValueNotifier(false);

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    romanize.value = p.getBool('lyrics.romanize') ?? false;
    translate.value = p.getBool('lyrics.translate') ?? false;
    romanize.addListener(() => p.setBool('lyrics.romanize', romanize.value));
    translate.addListener(() => p.setBool('lyrics.translate', translate.value));
  }

  /// The device's language ("id", "en"…).
  static String get targetLanguage => PlatformDispatcher.instance.locale.languageCode;

  /// Letters outside the Latin script: kana, kanji, hangul, Cyrillic, Arabic…
  static final _nonLatin = RegExp(r'(?![\p{Script=Latin}])\p{L}', unicode: true);

  static bool hasNonLatin(String s) => _nonLatin.hasMatch(s);

  static final _http = http.Client();
  static final _cache = <String, Future<List<LineExtras>>>{};

  /// Extras for each of [lines], in order. Lines that need nothing get
  /// [LineExtras.none]; throws when neither service could be reached.
  static Future<List<LineExtras>> of(List<String> lines, {String? to, http.Client? client}) {
    final lang = to ?? targetLanguage;
    final key = '$lang\u0000${lines.join('\n')}';
    final future = _cache[key] ??= _of(lines, lang, client ?? _http);
    while (_cache.length > 16) {
      _cache.remove(_cache.keys.first);
    }
    return future.catchError((Object e) {
      _cache.remove(key);
      throw e;
    });
  }

  static Future<List<LineExtras>> _of(List<String> lines, String to, http.Client c) async {
    // Choruses repeat: ask for each distinct line once.
    final unique = {
      for (final l in lines.map((l) => l.trim()))
        if (l.isNotEmpty) l,
    }.toList();
    if (unique.isEmpty) return [for (final _ in lines) LineExtras.none];
    Map<String, LineExtras> found;
    try {
      found = await _google(unique, to, c);
    } catch (_) {
      found = await _unison(unique, to, c);
    }
    return [for (final l in lines) found[l.trim()] ?? LineExtras.none];
  }

  /// Keeps a value only when it adds something to [line].
  static String? _useful(String? value, String line) {
    final v = value?.trim();
    return v == null || v.isEmpty || v.toLowerCase() == line.toLowerCase() ? null : v;
  }

  /// Lines go out joined by a separator that survives both translation and
  /// romanization, chunked to keep the URL short enough.
  static Future<Map<String, LineExtras>> _google(List<String> lines, String to, http.Client c) async {
    var sep = '0000';
    while (lines.any((l) => l.contains(sep))) {
      sep += '0';
    }
    final chunks = <List<String>>[[]];
    var size = 0;
    for (final l in lines) {
      final cost = Uri.encodeQueryComponent('$l\n$sep\n').length;
      if (size + cost > 8000 && chunks.last.isNotEmpty) {
        chunks.add([]);
        size = 0;
      }
      chunks.last.add(l);
      size += cost;
    }
    final out = <String, LineExtras>{};
    for (final chunk in chunks) {
      final res = await c.get(
        Uri.https('translate.googleapis.com', '/translate_a/single', {
          'client': 'dict-chrome-ex',
          'sl': 'auto',
          'tl': to,
          'dt': ['t', 'rm'],
          'q': chunk.join('\n$sep\n'),
        }),
        headers: const {'User-Agent': 'Mozilla/5.0'},
      );
      // A blocked client gets an HTML "Sorry" page, still with a 200 now and then.
      if (res.statusCode != 200 || !res.body.startsWith('[')) throw HttpException('Google Translate ${res.statusCode}');
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as List;
      final parts = (data[0] as List? ?? const []).whereType<List>();
      final translated = parts.where((p) => p.isNotEmpty && p[0] is String).map((p) => p[0] as String).join();
      final romanized = parts
          .where((p) => p.length > 2 && p[0] == null)
          .map((p) => (p.length > 3 ? p[3] : null) ?? p[2] ?? '')
          .join();
      final sameLanguage = data.length > 2 && data[2] == to;
      List<String>? split(String s) {
        final pieces = s.split(RegExp('\\s*$sep\\s*')).map((p) => p.trim()).toList();
        return pieces.length == chunk.length ? pieces : null;
      }

      // A reply that doesn't split back into the same lines can't be lined up.
      final t = sameLanguage ? null : split(translated);
      final r = split(romanized);
      for (var i = 0; i < chunk.length; i++) {
        final line = chunk[i];
        out[line] = LineExtras(
          romanized: hasNonLatin(line) ? _useful(r?[i], line) : null,
          translation: _useful(t?[i], line),
        );
      }
    }
    return out;
  }

  /// Better Lyrics' translation service: translations only, no pronunciation.
  static Future<Map<String, LineExtras>> _unison(List<String> lines, String to, http.Client c) async {
    for (var attempt = 0; ; attempt++) {
      final res = await c.post(
        Uri.https('unison.betterlyrics.org', '/translate'),
        headers: const {
          'content-type': 'application/json',
          'User-Agent': 'OpenMusic (https://github.com/Araryarch67/openmusic)',
        },
        body: jsonEncode({'lines': lines, 'to': to}),
      );
      // Its gateway answers 502 now and then; the next try usually works.
      if (res.statusCode == 502 && attempt == 0) continue;
      if (res.statusCode != 200) throw HttpException('Better Lyrics translate ${res.statusCode}');
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final out = (data['lines'] as List? ?? const []).cast<Map<String, dynamic>>();
      if (out.length != lines.length) throw const HttpException('Better Lyrics translate: lines don\'t match');
      return {
        for (var i = 0; i < lines.length; i++)
          lines[i]: LineExtras(
            translation: out[i]['needsTranslation'] == false
                ? null
                : _useful(out[i]['translation'] as String?, lines[i]),
          ),
      };
    }
  }
}
