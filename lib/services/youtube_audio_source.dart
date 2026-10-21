// StreamAudioSource/Response are just_audio's documented way to feed custom byte streams;
// they are flagged experimental but stable across 0.9-0.10.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'youtube_importer.dart';
import 'youtube_stream.dart';
import 'ytdlp.dart';

/// Streams a YouTube video's audio track without downloading it first.
///
/// Stream URLs expire after a few hours, so nothing is resolved until the
/// player actually asks for bytes; a whole playlist can be queued up front.
/// Byte ranges are fetched in chunks because googlevideo rejects very large
/// single ranges.
class YoutubeAudioSource extends StreamAudioSource {
  YoutubeAudioSource(this.videoId, {required this.yt, this.aac = false, super.tag});

  static const _chunkSize = 1 << 20;

  /// The first bytes of the next songs in the queue, fetched while the
  /// current one plays ([preload]), so skipping starts without the network.
  static final _heads = <String, ({int total, Uint8List bytes})>{};
  static final _loadingHeads = <String, Future<void>>{};
  static const _headSize = 256 << 10; // ~15 s of 128 kbps Opus
  static final _headHttp = http.Client();

  /// Resolves [videoId] and fetches the start of its audio, once.
  static Future<void> preload(String videoId) =>
      _heads.containsKey(videoId) ? Future.value() : _loadingHeads[videoId] ??= _fetchHead(videoId);

  static Future<void> _fetchHead(String videoId) async {
    try {
      final r = await YoutubeStream.best(videoId);
      final total = r.size;
      if (total == null) return;
      final res = await _headHttp.get(
        r.url,
        headers: {'Range': 'bytes=0-${(_headSize < total ? _headSize : total) - 1}'},
      );
      if (res.statusCode != 206 && res.statusCode != 200) return;
      _heads[videoId] = (total: total, bytes: res.bodyBytes);
      while (_heads.length > 4) {
        _heads.remove(_heads.keys.first);
      }
    } catch (_) {
      // Just a head start; playback fetches it normally.
    } finally {
      _loadingHeads.remove(videoId);
    }
  }

  final String videoId;
  final YoutubeExplode yt;

  /// AAC instead of Opus (casting: most network players can't decode Opus).
  final bool aac;
  final _http = http.Client();

  /// YouTube's player API (yt-dlp on desktop if refused), with
  /// youtube_explode as a last resort on phones.
  Future<({Uri url, int total, String mime})> _resolve() async {
    try {
      final r = await YoutubeStream.best(videoId, aac: aac);
      if (r.size case final size?) return (url: r.url, total: size, mime: r.mimeType);
      if (YtDlp.supported) throw StateError('Unknown stream size for $videoId');
    } catch (e) {
      if (YtDlp.supported) rethrow;
      debugPrint('YouTube stream lookup failed, trying youtube_explode: $e');
    }
    final manifest = await yt.videos.streams.getManifest(videoId);
    final best = YoutubeImporter.pickBestAudio(manifest.audioOnly, appleOnly: aac ? true : null);
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
      stream: _ranged(info.url, from, to, info.total),
    );
  }

  /// just_audio's proxy drops stream errors without a word (playback just
  /// stops), so say what went wrong here.
  Stream<List<int>> _ranged(Uri url, int from, int to, int total) =>
      _fetchRange(url, from, to, total).handleError((Object e, StackTrace st) {
        debugPrint('YouTube stream $videoId failed at bytes $from-$to: $e');
        Error.throwWithStackTrace(e, st);
      });

  Stream<List<int>> _fetchRange(Uri url, int from, int to, int total) async* {
    var source = url;
    var retried = false;
    var pos = from;
    // From memory as far as the preloaded start of the file reaches.
    final head = aac ? null : _heads[videoId];
    if (head != null && head.total == total && pos < head.bytes.length) {
      final end = head.bytes.length < to ? head.bytes.length : to;
      yield Uint8List.sublistView(head.bytes, pos, end);
      pos = end;
    }
    var dropped = 0;
    while (pos < to) {
      final last = (pos + _chunkSize).clamp(0, to) - 1;
      try {
        final req = http.Request('GET', source)..headers['Range'] = 'bytes=$pos-$last';
        final res = await _http.send(req);
        if (res.statusCode != 200 && res.statusCode != 206) {
          await res.stream.drain<void>();
          // Usually an expired or throttled URL: resolve a fresh one and retry once.
          if (!retried) {
            retried = true;
            YoutubeStream.invalidateEverywhere(videoId);
            source = (await _resolve()).url;
            continue;
          }
          throw http.ClientException('HTTP ${res.statusCode} while streaming $videoId', source);
        }
        await for (final bytes in res.stream) {
          yield bytes;
          pos += bytes.length;
        }
        pos = last + 1;
        dropped = 0;
      } on http.ClientException catch (e) {
        if (e.message.startsWith('HTTP ')) rethrow;
        // The connection dropped mid-chunk: carry on from the last byte sent.
        // (just_audio's proxy swallows stream errors, so playback would just stop.)
        if (++dropped > 3) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * dropped));
      } on SocketException {
        if (++dropped > 3) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * dropped));
      }
    }
  }
}
