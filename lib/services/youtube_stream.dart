import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ytdlp.dart';

/// Finds a YouTube song's audio stream on phones, where there is no yt-dlp.
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

  /// The visitor id from a watch page, reused for a few hours.
  static Future<String?> _visitorData(String videoId, {bool fresh = false}) {
    final stale = _visitorAt == null || DateTime.now().difference(_visitorAt!) > const Duration(hours: 6);
    if (fresh || stale || _visitor == null) {
      _visitorAt = DateTime.now();
      _visitor = () async {
        final page = await _http.get(
          Uri.parse('https://www.youtube.com/watch?v=$videoId&bpctr=9999999999&has_verified=1'),
          headers: {'user-agent': _pageUa, 'accept-language': 'en-US,en;q=0.9'},
        );
        return RegExp(r'"VISITOR_DATA":"([^"]+)"').firstMatch(page.body)?.group(1);
      }();
      _visitor!.then<void>((_) {}, onError: (Object _) => _visitor = null);
    }
    return _visitor!;
  }

  static final _resolved = <String, Future<ResolvedAudio>>{};

  /// The best original audio stream of [videoId], cached while its URL is fresh.
  static Future<ResolvedAudio> resolve(String videoId) {
    final cached = _resolved[videoId];
    if (cached != null) return cached.then((r) => r.isFresh ? r : _refresh(videoId));
    return _refresh(videoId);
  }

  /// Forget a cached URL (e.g. after the server rejected it).
  static void invalidate(String videoId) => _resolved.remove(videoId);

  static Future<ResolvedAudio> _refresh(String videoId) {
    final future = _player(videoId).catchError((Object _) => _player(videoId, freshVisitor: true));
    _resolved[videoId] = future;
    future.then<void>((_) {}, onError: (Object _) => _resolved.remove(videoId));
    return future;
  }

  static Future<ResolvedAudio> _player(String videoId, {bool freshVisitor = false}) async {
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
    final best = pickBest(formats, apple: Platform.isIOS || Platform.isMacOS);
    if (best == null) throw StateError('No audio stream for this song.');
    final url = Uri.parse(best['url'] as String);
    final mime = best['mimeType'] as String;
    return ResolvedAudio(
      url: url,
      formatId: '${best['itag']}',
      ext: mime.startsWith('audio/webm') ? 'webm' : 'm4a',
      codec: RegExp(r'codecs="([^"]+)"').firstMatch(mime)?.group(1) ?? '',
      kbps: (((best['averageBitrate'] ?? best['bitrate']) as num?)?.toDouble() ?? 0) ~/ 1000,
      size: int.tryParse(best['contentLength'] as String? ?? '') ?? int.tryParse(url.queryParameters['clen'] ?? ''),
      resolvedAt: DateTime.now(),
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
