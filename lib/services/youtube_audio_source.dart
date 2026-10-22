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

/// How a YouTube song is being streamed, for Stats for nerds.
class StreamStats {
  /// What YouTube serves for it (null until resolved).
  ResolvedAudio? stream;

  /// Bytes received from YouTube for this song so far, the preloaded start included.
  int received = 0;

  /// Speed of the latest request, in bits per second. Time spent waiting for
  /// the player to read is left out, so this is the connection's speed.
  double? bitsPerSecond;

  void _count(int bytes, Duration took) {
    // A short read (the end of the file, a seek) says little about the connection.
    if (bytes >= 64 << 10 && took > Duration.zero) bitsPerSecond = bytes * 8 / (took.inMicroseconds / 1e6);
  }
}

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

  static final _stats = <String, StreamStats>{};

  /// How [videoId] is being streamed, if it has been this session.
  static StreamStats? statsOf(String videoId) => _stats[videoId];

  static StreamStats _statsFor(String videoId) {
    final s = _stats.remove(videoId) ?? StreamStats();
    _stats[videoId] = s; // newest last
    while (_stats.length > 8) {
      _stats.remove(_stats.keys.first);
    }
    return s;
  }

  /// Resolves [videoId] and fetches the start of its audio, once.
  static Future<void> preload(String videoId) =>
      _heads.containsKey(videoId) ? Future.value() : _loadingHeads[videoId] ??= _fetchHead(videoId);

  static Future<void> _fetchHead(String videoId) async {
    try {
      final r = await YoutubeStream.best(videoId);
      final total = r.size;
      if (total == null) return;
      final took = Stopwatch()..start();
      final res = await _headHttp.get(
        r.url,
        headers: {'Range': 'bytes=0-${(_headSize < total ? _headSize : total) - 1}'},
      );
      if (res.statusCode != 206 && res.statusCode != 200) return;
      _statsFor(videoId)
        ..stream = r
        ..received += res.bodyBytes.length
        .._count(res.bodyBytes.length, took.elapsed);
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
  /// youtube_explode as a last resort on phones. Always has a size.
  Future<ResolvedAudio> _resolve() async => _statsFor(videoId).stream = await _find();

  Future<ResolvedAudio> _find() async {
    try {
      final r = await YoutubeStream.best(videoId, aac: aac);
      if (r.size != null) return r;
      if (YtDlp.supported) throw StateError('Unknown stream size for $videoId');
    } catch (e) {
      if (YtDlp.supported) rethrow;
      debugPrint('YouTube stream lookup failed, trying youtube_explode: $e');
    }
    final manifest = await yt.videos.streams.getManifest(videoId);
    final best = YoutubeImporter.pickBestAudio(manifest.audioOnly, appleOnly: aac ? true : null);
    if (best == null) throw StateError('No audio stream for $videoId');
    return ResolvedAudio(
      url: best.url,
      formatId: '${best.tag}',
      ext: best.container == StreamContainer.webM ? 'webm' : 'm4a',
      codec: best.audioCodec,
      kbps: best.bitrate.kiloBitsPerSecond.round(),
      size: best.size.totalBytes,
      resolvedAt: DateTime.now(),
      via: 'youtube_explode',
    );
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final info = await _resolve();
    final total = info.size!;
    final from = start ?? 0;
    final to = (end ?? total).clamp(from, total);
    return StreamAudioResponse(
      sourceLength: total,
      contentLength: to - from,
      offset: from,
      contentType: info.mimeType,
      stream: _ranged(info.url, from, to, total),
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
    final stats = _statsFor(videoId);
    while (pos < to) {
      final last = (pos + _chunkSize).clamp(0, to) - 1;
      try {
        final req = http.Request('GET', source)..headers['Range'] = 'bytes=$pos-$last';
        // Runs only while waiting for the network, not while the player isn't reading.
        final took = Stopwatch()..start();
        var got = 0;
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
          got += bytes.length;
          stats.received += bytes.length;
          took.stop();
          yield bytes;
          took.start();
          pos += bytes.length;
        }
        stats._count(got, took.elapsed);
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
