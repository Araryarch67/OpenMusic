// StreamAudioSource/Response are just_audio's documented way to feed custom byte streams;
// they are flagged experimental but stable across 0.9-0.10.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'youtube_importer.dart';
import 'ytdlp.dart';

/// Streams a YouTube video's audio track without downloading it first.
///
/// Stream URLs expire after a few hours, so nothing is resolved until the
/// player actually asks for bytes; a whole playlist can be queued up front.
/// Byte ranges are fetched in chunks because googlevideo rejects very large
/// single ranges.
class YoutubeAudioSource extends StreamAudioSource {
  YoutubeAudioSource(this.videoId, {required this.yt, super.tag});

  static const _chunkSize = 1 << 20;

  final String videoId;
  final YoutubeExplode yt;
  final _http = http.Client();

  /// Desktop resolves through yt-dlp (works with current YouTube); mobile uses the in-app extractor.
  Future<({Uri url, int total, String mime})> _resolve() async {
    if (YtDlp.supported) {
      final r = await YtDlp.resolve(videoId);
      final size = r.size;
      if (size == null) throw StateError('Unknown stream size for $videoId');
      return (url: r.url, total: size, mime: r.mimeType);
    }
    final manifest = await yt.videos.streams.getManifest(videoId);
    final best = YoutubeImporter.pickBestAudio(manifest.audioOnly);
    if (best == null) throw StateError('No audio stream for $videoId');
    return (
      url: best.url,
      total: best.size.totalBytes,
      mime: best.container == StreamContainer.webM ? 'audio/webm' : 'audio/mp4',
    );
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final info = await _resolve();
    final from = start ?? 0;
    final to = (end ?? info.total).clamp(from, info.total);
    return StreamAudioResponse(
      sourceLength: info.total,
      contentLength: to - from,
      offset: from,
      contentType: info.mime,
      stream: _ranged(info.url, from, to),
    );
  }

  Stream<List<int>> _ranged(Uri url, int from, int to) async* {
    var source = url;
    var retried = false;
    for (var pos = from; pos < to;) {
      final last = (pos + _chunkSize).clamp(0, to) - 1;
      final req = http.Request('GET', source)..headers['Range'] = 'bytes=$pos-$last';
      final res = await _http.send(req);
      if (res.statusCode != 200 && res.statusCode != 206) {
        await res.stream.drain<void>();
        // Usually an expired or throttled URL: resolve a fresh one and retry once.
        if (!retried) {
          retried = true;
          if (YtDlp.supported) YtDlp.invalidate(videoId);
          source = (await _resolve()).url;
          continue;
        }
        throw http.ClientException('HTTP ${res.statusCode} while streaming $videoId', source);
      }
      yield* res.stream;
      pos = last + 1;
    }
  }
}
