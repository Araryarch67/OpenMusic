import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/track.dart';
import 'ranged_download.dart';
import 'youtube_stream.dart';
import 'ytdlp.dart';

enum DownloadStatus { queued, downloading, done, failed, cancelled }

/// One video being turned into a library track.
class DownloadJob {
  DownloadJob({
    required this.videoId,
    required this.title,
    required this.channel,
    required this.thumbnailUrl,
    this.knownNames = false,
  });

  final String videoId;
  final String title;
  final String channel;

  /// [title] and [channel] are the song's real title and artist (a YouTube
  /// Music song), not a video title and uploader that still need splitting.
  final bool knownNames;
  final String thumbnailUrl;

  DownloadStatus status = DownloadStatus.queued;
  double progress = 0;

  /// e.g. "Opus · 160 kbps", known once the stream is picked.
  String? quality;

  /// File size once the stream is resolved, and how much of it has arrived.
  int? totalBytes;
  int receivedBytes = 0;

  /// Smoothed transfer rate; null until the first sample.
  double? bytesPerSecond;

  Duration? get eta {
    final total = totalBytes, rate = bytesPerSecond;
    if (total == null || rate == null || rate <= 0) return null;
    return Duration(milliseconds: ((total - receivedBytes) / rate * 1000).round());
  }

  String? error;
  Track? track;

  bool get isActive => status == DownloadStatus.queued || status == DownloadStatus.downloading;
}

/// What a pasted link resolved to, shown before the user commits to downloading.
sealed class YoutubePreview {
  const YoutubePreview();
}

class VideoPreview extends YoutubePreview {
  const VideoPreview(this.video);
  final Video video;
}

class PlaylistPreview extends YoutubePreview {
  const PlaylistPreview(this.playlist, this.videos);
  final Playlist playlist;
  final List<Video> videos;
}

/// Resolves YouTube links and downloads their audio-only stream into the app's
/// music folder, one job at a time.
class YoutubeImporter extends ChangeNotifier {
  YoutubeImporter({required this.onTrackReady});

  /// Called with each finished track so it can be added to the library.
  final Future<void> Function(Track track) onTrackReady;

  static const _maxPlaylistVideos = 200;

  final _yt = YoutubeExplode();

  /// Shared client, also used for streaming and YouTube search.
  YoutubeExplode get client => _yt;
  final List<DownloadJob> _jobs = [];

  List<DownloadJob> get jobs => List.unmodifiable(_jobs.reversed);
  int get activeCount => _jobs.where((j) => j.isActive).length;

  /// Overall progress of queued + running jobs, for the toolbar indicator.
  double? get activeProgress {
    final active = _jobs.where((j) => j.isActive).toList();
    if (active.isEmpty) return null;
    return active.fold(0.0, (sum, j) => sum + j.progress) / active.length;
  }

  static bool looksLikeYoutubeUrl(String text) =>
      VideoId.parseVideoId(text.trim()) != null || PlaylistId.parsePlaylistId(text.trim()) != null;

  /// Where downloads live: ~/Documents/OpenMusic/YouTube on desktop, the app's
  /// private documents folder on mobile.
  static Future<Directory> downloadsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final mobile = Platform.isAndroid || Platform.isIOS;
    final dir = Directory(mobile ? p.join(docs.path, 'YouTube') : p.join(docs.path, 'OpenMusic', 'YouTube'));
    return dir.create(recursive: true);
  }

  /// Looks up a link. Pure playlist links (`/playlist?list=`) resolve to the whole
  /// playlist; watch links resolve to the single video even if they carry a list.
  Future<YoutubePreview> resolve(String url) async {
    final text = url.trim();
    final videoId = VideoId.parseVideoId(text);
    if (videoId != null) return VideoPreview(await _yt.videos.get(videoId));
    final playlistId = PlaylistId.parsePlaylistId(text);
    if (playlistId == null) throw const FormatException('That doesn\'t look like a YouTube link.');
    final playlist = await _yt.playlists.get(playlistId);
    final videos = await _yt.playlists.getVideos(playlistId).take(_maxPlaylistVideos).toList();
    return PlaylistPreview(playlist, videos);
  }

  /// Queues videos for download; ones already queued or downloaded are skipped.
  /// Returns how many were newly queued.
  int enqueue(List<Video> videos) => _enqueue([
    for (final v in videos)
      DownloadJob(videoId: v.id.value, title: v.title, channel: v.author, thumbnailUrl: v.thumbnails.highResUrl),
  ]);

  /// Saves streamed YouTube Music songs for offline playback.
  int enqueueTracks(List<Track> tracks) => _enqueue([
    for (final t in tracks.where((t) => t.isRemote))
      DownloadJob(
        videoId: t.videoId!,
        title: t.title,
        channel: t.artist,
        thumbnailUrl: t.artworkUrl ?? 'https://i.ytimg.com/vi/${t.videoId}/hqdefault.jpg',
        knownNames: true,
      ),
  ]);

  /// The newest download of [videoId], if any (queued, running, done or failed).
  DownloadJob? jobFor(String videoId) => _jobs.where((j) => j.videoId == videoId).lastOrNull;

  int _enqueue(List<DownloadJob> fresh) {
    var added = 0;
    for (final job in fresh) {
      final existing = _jobs.where((j) => j.videoId == job.videoId).firstOrNull;
      if (existing != null && existing.status != DownloadStatus.failed && existing.status != DownloadStatus.cancelled) {
        continue;
      }
      _jobs.remove(existing);
      _jobs.add(job);
      added++;
    }
    notifyListeners();
    unawaited(_drain());
    return added;
  }

  void retry(DownloadJob job) {
    job
      ..status = DownloadStatus.queued
      ..progress = 0
      ..error = null;
    notifyListeners();
    unawaited(_drain());
  }

  void cancel(DownloadJob job) {
    if (!job.isActive) return;
    // The running download notices this between chunks and cleans up.
    job.status = DownloadStatus.cancelled;
    notifyListeners();
  }

  void clearFinished() {
    _jobs.removeWhere((j) => !j.isActive);
    notifyListeners();
  }

  /// Songs downloaded at the same time. Most of each job is yt-dlp resolving
  /// the stream (~1.5 s), so overlapping jobs speeds up playlists a lot.
  static const _parallelJobs = 3;
  int _running = 0;

  Future<void> _drain() async {
    while (_running < _parallelJobs) {
      final job = _jobs.where((j) => j.status == DownloadStatus.queued).firstOrNull;
      if (job == null) return;
      job.status = DownloadStatus.downloading;
      _running++;
      unawaited(
        _download(job).whenComplete(() {
          _running--;
          _drain();
        }),
      );
    }
  }

  /// Exact size and quality of what a download would fetch. Also warms the
  /// cache, so a download started right after skips resolving.
  Future<({int? size, String quality})?> peekAudio(String videoId) async {
    try {
      final r = await YoutubeStream.best(videoId);
      return (size: r.size, quality: r.quality);
    } catch (_) {
      return null;
    }
  }

  /// Best audio as (url, size, file extension, quality label).
  Future<({Uri url, int? size, String ext, String quality})> _resolveAudio(String videoId) async {
    // YouTube's player API (yt-dlp on desktop if refused), then the in-app extractor.
    try {
      final r = await YoutubeStream.best(videoId);
      return (url: r.url, size: r.size, ext: r.ext == 'webm' ? 'webm' : 'm4a', quality: r.quality);
    } catch (e) {
      if (YtDlp.supported) rethrow;
      debugPrint('YouTube stream lookup failed, trying youtube_explode: $e');
    }
    final manifest = await _yt.videos.streams.getManifest(videoId);
    final stream = pickBestAudio(manifest.audioOnly);
    if (stream == null) throw StateError('No playable audio stream for this video.');
    return (
      url: stream.url,
      size: stream.size.totalBytes,
      ext: stream.container == StreamContainer.webM ? 'webm' : 'm4a',
      quality: describe(stream),
    );
  }

  Future<void> _download(DownloadJob job) async {
    notifyListeners();
    final dir = await downloadsDir();
    File? partFile;
    try {
      // Metadata and the stream URL resolve in parallel.
      final (video, audio) = await (_yt.videos.get(job.videoId), _resolveAudio(job.videoId)).wait;
      job.quality = audio.quality;
      // Stored byte-for-byte as YouTube serves it: re-encoding could only lose quality.
      final audioFile = File(p.join(dir.path, '${job.videoId}.${audio.ext}'));
      partFile = File('${audioFile.path}.part');
      notifyListeners();

      var lastNotified = 0.0;
      var sampleBytes = 0;
      final sampleClock = Stopwatch()..start();
      job
        ..totalBytes = audio.size
        ..receivedBytes = 0
        ..bytesPerSecond = null;
      final thumbnail = _saveThumbnail(video, p.join(dir.path, '${job.videoId}.jpg'));
      try {
        await rangedDownload(
          url: audio.url,
          out: partFile,
          totalBytes: audio.size,
          isCancelled: () => job.status == DownloadStatus.cancelled,
          onProgress: (received, total) {
            job
              ..progress = received / total
              ..totalBytes = total
              ..receivedBytes = received;
            // Exponential moving average over ~250 ms windows keeps the speed readout steady.
            final elapsed = sampleClock.elapsedMicroseconds;
            if (elapsed >= 250000) {
              final rate = (received - sampleBytes) / (elapsed / 1e6);
              job.bytesPerSecond = job.bytesPerSecond == null ? rate : job.bytesPerSecond! * 0.6 + rate * 0.4;
              sampleBytes = received;
              sampleClock.reset();
            }
            if (job.progress - lastNotified >= 0.01) {
              lastNotified = job.progress;
              notifyListeners();
            }
          },
        );
      } catch (_) {
        // A stale cached URL is the usual cause; resolve fresh next time.
        YoutubeStream.invalidateEverywhere(job.videoId);
        rethrow;
      }
      await partFile.rename(audioFile.path);
      await thumbnail;

      // YouTube Music already named the song; only a bare video title needs guessing.
      final names = job.knownNames ? (title: job.title, artist: job.channel) : parseTitle(video.title, video.author);
      final track = Track(
        id: Uri.file(audioFile.path).toString(),
        uri: Uri.file(audioFile.path),
        title: names.title,
        artist: names.artist,
        duration: video.duration,
        addedAt: DateTime.now().millisecondsSinceEpoch,
        tagged: true,
        sourceUrl: video.url,
      );
      job
        ..track = track
        ..progress = 1
        ..status = DownloadStatus.done;
      await onTrackReady(track);
    } catch (e) {
      if (partFile != null && partFile.existsSync()) partFile.deleteSync();
      if (job.status != DownloadStatus.cancelled) {
        job
          ..status = DownloadStatus.failed
          ..error = _friendlyError(e);
      }
    } finally {
      notifyListeners();
    }
  }

  /// YouTube has no lossless audio; the best it serves is Opus (~130–160 kbps)
  /// or AAC (128 kbps). Take the highest-bitrate stream, preferring Opus on
  /// ties, except on Apple platforms where AVPlayer can't play Opus-in-WebM.
  static AudioOnlyStreamInfo? pickBestAudio(Iterable<AudioOnlyStreamInfo> streams, {bool? appleOnly}) {
    final apple = appleOnly ?? (Platform.isIOS || Platform.isMacOS);
    final candidates = streams
        .where((s) => !apple || s.container == StreamContainer.mp4)
        .where((s) => !_isDrcOrDubbed(s))
        .toList();
    if (candidates.isEmpty) return apple ? null : streams.firstOrNull;
    // Opus is more efficient than AAC, so near-equal bitrates go to Opus.
    int score(AudioOnlyStreamInfo s) => s.bitrate.bitsPerSecond + (_isOpus(s) ? 16000 : 0);
    candidates.sort((a, b) => score(b).compareTo(score(a)));
    return candidates.first;
  }

  static bool _isOpus(AudioOnlyStreamInfo s) => s.audioCodec.toLowerCase().contains('opus');

  /// Skip "stable volume" (DRC) and non-original dubbed tracks: they're processed or not the original mix.
  static bool _isDrcOrDubbed(AudioOnlyStreamInfo s) {
    final xtags = Uri.decodeComponent(s.url.queryParameters['xtags'] ?? '');
    final track = s.audioTrack;
    return xtags.contains('drc=1') || (track != null && !track.audioIsDefault);
  }

  static String describe(AudioOnlyStreamInfo s) =>
      '${_isOpus(s) ? 'Opus' : 'AAC'} · ${s.bitrate.kiloBitsPerSecond.round()} kbps';

  static Future<void> _saveThumbnail(Video video, String path) async {
    for (final url in [video.thumbnails.maxResUrl, video.thumbnails.highResUrl]) {
      try {
        final res = await http.get(Uri.parse(url));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          await File(path).writeAsBytes(res.bodyBytes);
          return;
        }
      } catch (_) {
        // Cover art is optional.
      }
    }
  }

  static String _friendlyError(Object e) => switch (e) {
    // Subclass first: VideoUnavailableException extends VideoUnplayableException.
    VideoUnavailableException() => 'This video is unavailable.',
    VideoUnplayableException() => 'This video can\'t be played (private, age-restricted or region-locked).',
    SocketException() || http.ClientException() => 'Network error. Check your connection and retry.',
    StateError(:final message) => message,
    _ => e.toString(),
  };

  static final _noise = RegExp(
    r'\s*[\(\[]\s*(official\s*|oficial\s*|officiel(le)?\s*)?'
    r'(music\s*|lyrics?\s*|letra\s*|audio\s*|áudio\s*|hd\s*|hq\s*|4k\s*|m/?v\s*|visuali[sz]er\s*|video\s*|vídeo\s*|clip\s*)+'
    r'(oficial\s*|officiel(le)?\s*)?[\)\]]',
    caseSensitive: false,
  );
  static final _channelSuffix = RegExp(r'(\s*-\s*Topic|VEVO|\s*Official)$', caseSensitive: false);

  /// Turns "Artist - Song (Official Video)" into title/artist; falls back to the channel name.
  /// Also handles the reversed "Song - Artist" order when the channel names the artist.
  static ({String title, String artist}) parseTitle(String rawTitle, String channel) {
    var title = rawTitle.replaceAll(_noise, '').trim();
    title = title.replaceFirst(RegExp(r'\s*\|.*$'), '').trim();
    final channelName = channel.replaceAll(_channelSuffix, '').trim();
    final dash = RegExp(r'\s+[-–—]\s+').firstMatch(title);
    if (dash != null) {
      final left = title.substring(0, dash.start).trim();
      final right = title.substring(dash.end).trim();
      if (left.isNotEmpty && right.isNotEmpty) {
        bool names(String side) => channelName.isNotEmpty && side.toLowerCase().contains(channelName.toLowerCase());
        if (names(right) && !names(left)) return (title: left, artist: right);
        return (title: right, artist: left);
      }
    }
    return (title: title.isEmpty ? rawTitle : title, artist: channelName.isEmpty ? channel : channelName);
  }

  /// iOS moves the app container on updates, so re-point downloaded tracks at
  /// the current downloads folder when their stored path has gone stale.
  static Future<Track> relocate(Track track) async {
    final path = track.path;
    if (track.sourceUrl == null || path == null || File(path).existsSync()) return track;
    final moved = File(p.join((await downloadsDir()).path, p.basename(path)));
    return moved.existsSync() ? track.copyWith(uri: Uri.file(moved.path)) : track;
  }

  @override
  void dispose() {
    for (final j in _jobs.where((j) => j.isActive)) {
      j.status = DownloadStatus.cancelled;
    }
    _yt.close();
    super.dispose();
  }
}
