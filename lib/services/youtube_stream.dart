import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ytdlp.dart';

/// Finds a YouTube song's audio stream with one request to YouTube's player
/// API (~0.2 s once warmed up). Desktop falls back to yt-dlp ([best]) when
/// YouTube refuses it; phones, which have no yt-dlp, to youtube_explode.
///
/// Asks YouTube's player API as the Apple Vision Pro app (`VISIONOS`), the
/// client yt-dlp itself uses when it can't run JavaScript: its stream URLs
/// need no signature deciphering and no PO token. URLs from the Android
/// clients youtube_explode uses stop after the first megabyte (HTTP 403).
///
/// The request needs a visitor id from the watch page, or YouTube answers
/// LOGIN_REQUIRED ("confirm you're not a bot").
abstract final class YoutubeStream {
  static const _ua =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
  static const _pageUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

  // Kept in step with yt-dlp's INNERTUBE_CLIENTS['visionos'].
  static const _client = {
    'clientName': 'VISIONOS',
    'clientVersion': '1.02',
    'deviceMake': 'Apple',
    'deviceModel': 'RealityDevice17,1',
    'userAgent': _ua,
    'osName': 'visionOS',
    'osVersion': '26.5.23O471',
    'hl': 'en',
  };

  static final _http = http.Client();

  static Future<String?>? _visitor;
  static DateTime? _visitorAt;
  static const _visitorKey = 'youtube.visitor.v1';
  static const _visitorLife = Duration(hours: 6);

  /// A visitor id, reused for a few hours, across restarts too (the first
  /// song after launch then needs no extra request).
  static Future<String?> _visitorData(String videoId, {bool fresh = false}) {
    final stale = _visitorAt == null || DateTime.now().difference(_visitorAt!) > _visitorLife;
    if (fresh || stale || _visitor == null) {
      _visitorAt = DateTime.now();
      _visitor = () async {
        if (!fresh) {
          final saved = await _savedVisitor();
          if (saved != null) return saved;
        }
        final id = await _fetchVisitor(videoId);
        if (id != null) _saveVisitor(id).ignore();
        return id;
      }();
      _visitor!.then<void>((_) {}, onError: (Object _) => _visitor = null);
    }
    return _visitor!;
  }

  static Future<String?> _savedVisitor() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_visitorKey)?.split(' ');
      if (saved == null || saved.length != 2) return null;
      final at = DateTime.fromMillisecondsSinceEpoch(int.tryParse(saved[0]) ?? 0);
      if (DateTime.now().difference(at) > _visitorLife) return null;
      _visitorAt = at;
      return saved[1];
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveVisitor(String id) async =>
      (await SharedPreferences.getInstance()).setString(_visitorKey, '${DateTime.now().millisecondsSinceEpoch} $id');

  /// InnerTube's visitor_id endpoint (~1 KB); the watch page (~1.4 MB) if that fails.
  static Future<String?> _fetchVisitor(String videoId) async {
    try {
      final res = await _http
          .post(
            Uri.parse('https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false'),
            headers: {'content-type': 'application/json', 'user-agent': _pageUa},
            body: jsonEncode({
              'context': {
                'client': {'clientName': 'WEB', 'clientVersion': '2.20251001.00.00', 'hl': 'en'},
              },
            }),
          )
          .timeout(const Duration(seconds: 10));
      final id = ((jsonDecode(res.body) as Map)['responseContext'] as Map?)?['visitorData'];
      if (res.statusCode == 200 && id is String && id.isNotEmpty) return id;
    } catch (e) {
      debugPrint('visitor_id failed, reading the watch page: $e');
    }
    final page = await _http.get(
      Uri.parse('https://www.youtube.com/watch?v=$videoId&bpctr=9999999999&has_verified=1'),
      headers: {'user-agent': _pageUa, 'accept-language': 'en-US,en;q=0.9'},
    );
    return RegExp(r'"VISITOR_DATA":"([^"]+)"').firstMatch(page.body)?.group(1);
  }

  /// Fetches the visitor id in the background, so the first song starts fast.
  static void warmUp() => _visitorData('dQw4w9WgXcQ').ignore();

  /// The stream to play or download: the player API first, then yt-dlp where
  /// there is one (much slower: a process per song, but it keeps up with
  /// YouTube's changes). Both are cached while the URL is fresh.
  ///
  /// [aac] asks for AAC even where Opus would be better, for players that
  /// can't decode Opus (most TVs and speakers on the network).
  static Future<ResolvedAudio> best(String videoId, {bool aac = false}) async {
    try {
      return await resolve(videoId, aac: aac);
    } catch (e) {
      if (!YtDlp.supported) rethrow;
      debugPrint('YouTube player API failed for $videoId, using yt-dlp: $e');
      return YtDlp.resolve(videoId, aac: aac);
    }
  }

  /// Forget [videoId]'s URL everywhere (e.g. after the server rejected it).
  static void invalidateEverywhere(String videoId) {
    invalidate(videoId);
    if (YtDlp.supported) YtDlp.invalidate(videoId);
  }

  static final _resolved = <String, Future<ResolvedAudio>>{};

  /// The best original audio stream of [videoId], cached while its URL is fresh.
  static Future<ResolvedAudio> resolve(String videoId, {bool aac = false}) {
    final cached = _resolved[aac ? 'aac:$videoId' : videoId];
    if (cached != null) return cached.then((r) => r.isFresh ? r : _refresh(videoId, aac));
    return _refresh(videoId, aac);
  }

  /// Forget a cached URL (e.g. after the server rejected it).
  static void invalidate(String videoId) => _resolved
    ..remove(videoId)
    ..remove('aac:$videoId');

  static Future<ResolvedAudio> _refresh(String videoId, bool aac) {
    final key = aac ? 'aac:$videoId' : videoId;
    final future = _player(videoId, aac: aac).catchError((Object _) => _player(videoId, aac: aac, freshVisitor: true));
    _resolved[key] = future;
    future.then<void>((_) {}, onError: (Object _) => _resolved.remove(key));
    return future;
  }

  static Future<ResolvedAudio> _player(String videoId, {bool aac = false, bool freshVisitor = false}) async {
    final visitor = await _visitorData(videoId, fresh: freshVisitor);
    final res = await _http
        .post(
          Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
          headers: {
            'content-type': 'application/json',
            'user-agent': _ua,
            'origin': 'https://www.youtube.com',
            'x-youtube-client-name': '101',
            'x-youtube-client-version': '1.02',
            'x-goog-visitor-id': ?visitor,
          },
          body: jsonEncode({
            'context': {
              'client': {..._client, 'visitorData': ?visitor},
            },
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw StateError('YouTube replied ${res.statusCode}');
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final playability = j['playabilityStatus'] as Map<String, dynamic>?;
    if (playability?['status'] != 'OK') {
      throw StateError(
        (playability?['reason'] as String?) ?? 'This song can\'t be played (${playability?['status']}).',
      );
    }
    final formats = ((j['streamingData'] as Map<String, dynamic>?)?['adaptiveFormats'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final best = pickBest(formats, apple: aac || Platform.isIOS || Platform.isMacOS);
    if (best == null) throw StateError('No audio stream for this song.');
    final url = Uri.parse(best['url'] as String);
    final mime = best['mimeType'] as String;
    final loudness = (j['playerConfig'] as Map<String, dynamic>?)?['audioConfig'] as Map<String, dynamic>?;
    return ResolvedAudio(
      url: url,
      formatId: '${best['itag']}',
      ext: mime.startsWith('audio/webm') ? 'webm' : 'm4a',
      codec: RegExp(r'codecs="([^"]+)"').firstMatch(mime)?.group(1) ?? '',
      kbps: (((best['averageBitrate'] ?? best['bitrate']) as num?)?.toDouble() ?? 0) ~/ 1000,
      size: int.tryParse(best['contentLength'] as String? ?? '') ?? int.tryParse(url.queryParameters['clen'] ?? ''),
      resolvedAt: DateTime.now(),
      via: 'YouTube player API',
      loudness: (loudness?['trackAbsoluteLoudnessLkfs'] as num?)?.toDouble(),
      loudnessTarget: (loudness?['loudnessTargetLkfs'] as num?)?.toDouble(),
    );
  }

  /// Highest-bitrate original audio: Opus wins near-ties (better per bit),
  /// except on Apple, where AVPlayer can't play Opus-in-WebM. Leaves out
  /// "stable volume" (DRC) and dubbed tracks, and streams needing a signature.
  static Map<String, dynamic>? pickBest(List<Map<String, dynamic>> formats, {required bool apple}) {
    bool usable(Map<String, dynamic> f) {
      final mime = f['mimeType'] as String? ?? '';
      if (!mime.startsWith('audio/') || f['url'] is! String) return false;
      if (apple && !mime.startsWith('audio/mp4')) return false;
      if (f['isDrc'] == true || (f['xtags'] as String? ?? '').contains('drc')) return false;
      final track = f['audioTrack'] as Map<String, dynamic>?;
      return track == null || track['audioIsDefault'] != false;
    }

    int score(Map<String, dynamic> f) =>
        ((f['averageBitrate'] ?? f['bitrate']) as num? ?? 0).toInt() +
        ((f['mimeType'] as String).contains('opus') ? 16000 : 0);
    final candidates = formats.where(usable).toList()..sort((a, b) => score(b).compareTo(score(a)));
    return candidates.firstOrNull;
  }
}
