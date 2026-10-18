import 'package:path/path.dart' as p;

/// A single playable audio file in the library.
class Track {
  const Track({
    required this.id,
    required this.uri,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.trackNumber,
    this.addedAt = 0,
    this.tagged = false,
    this.sourceUrl,
    this.videoId,
    this.artworkUrl,
  });

  /// A YouTube / YouTube Music song that streams instead of playing from disk.
  factory Track.youtube({
    required String videoId,
    required String title,
    required String artist,
    Duration? duration,
    String? artworkUrl,
  }) => Track(
    id: 'yt:$videoId',
    uri: Uri.parse('https://music.youtube.com/watch?v=$videoId'),
    title: title,
    artist: artist,
    duration: duration,
    tagged: true,
    sourceUrl: 'https://music.youtube.com/watch?v=$videoId',
    videoId: videoId,
    artworkUrl: artworkUrl ?? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
  );

  /// Builds a track from a file URI, guessing title/artist from the
  /// "Artist - Title.ext" filename convention until real tags are read.
  factory Track.fromUri(Uri uri, {String? displayName}) {
    // pathSegments are already percent-decoded.
    final name = displayName ?? (uri.pathSegments.isEmpty ? uri.toString() : uri.pathSegments.last);
    final base = p.basenameWithoutExtension(name).replaceAll('_', ' ').trim();
    final parts = base.split(' - ');
    final hasArtist = parts.length >= 2;
    return Track(
      id: uri.toString(),
      uri: uri,
      title: hasArtist ? parts.sublist(1).join(' - ').trim() : base,
      artist: hasArtist ? parts.first.trim() : unknownArtist,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: json['id'] as String,
    uri: Uri.parse(json['uri'] as String),
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String?,
    duration: json['durationMs'] == null ? null : Duration(milliseconds: json['durationMs'] as int),
    trackNumber: json['trackNumber'] as int?,
    addedAt: json['addedAt'] as int? ?? 0,
    tagged: json['tagged'] as bool? ?? false,
    sourceUrl: json['sourceUrl'] as String?,
    videoId: json['videoId'] as String?,
    artworkUrl: json['artworkUrl'] as String?,
  );

  static const unknownArtist = 'Unknown artist';

  final String id;
  final Uri uri;
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final int? trackNumber;
  final int addedAt;

  /// Whether embedded tags have been read (so we don't re-scan every launch).
  final bool tagged;

  /// Page the audio was downloaded from (YouTube imports); null for local files.
  final String? sourceUrl;

  /// Set for streamed YouTube songs (not downloaded); playback resolves the audio on demand.
  final String? videoId;

  /// Cover art fetched over the network (streamed songs have no file to read it from).
  final String? artworkUrl;

  bool get isRemote => videoId != null;

  /// Local filesystem path, when the URI points at one (not Android content URIs).
  String? get path => uri.scheme == 'file' ? uri.toFilePath() : null;

  /// Groups tracks of the same album together, even across differently-tagged artists.
  String? get albumKey => album == null ? null : '${album!.toLowerCase()}|${artist.toLowerCase()}';

  Track copyWith({
    Uri? uri,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    int? trackNumber,
    bool? tagged,
  }) => Track(
    id: id,
    uri: uri ?? this.uri,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    duration: duration ?? this.duration,
    trackNumber: trackNumber ?? this.trackNumber,
    addedAt: addedAt,
    tagged: tagged ?? this.tagged,
    sourceUrl: sourceUrl,
    videoId: videoId,
    artworkUrl: artworkUrl,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'uri': uri.toString(),
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': duration?.inMilliseconds,
    'trackNumber': trackNumber,
    'addedAt': addedAt,
    'tagged': tagged,
    'sourceUrl': sourceUrl,
    'videoId': videoId,
    'artworkUrl': artworkUrl,
  };

  static const audioExtensions = {'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus', 'webm', 'wma', 'aiff', 'alac'};

  static bool isAudioPath(String path) {
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return audioExtensions.contains(ext);
  }
}

/// Album order: track number first, title as a tiebreak for untagged files.
int compareAlbumOrder(Track a, Track b) {
  final byNumber = (a.trackNumber ?? 1 << 20).compareTo(b.trackNumber ?? 1 << 20);
  return byNumber != 0 ? byNumber : a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// A group of tracks shown as a card / page (album, artist or the whole library).
class Collection {
  const Collection({required this.kind, required this.title, required this.subtitle, required this.tracks});

  final CollectionKind kind;
  final String title;
  final String subtitle;
  final List<Track> tracks;

  Track? get cover => tracks.isEmpty ? null : tracks.first;
}

enum CollectionKind {
  allSongs('Playlist'),
  album('Album'),
  youtube('Playlist'),
  remote('Playlist'),
  artist('Artist');

  const CollectionKind(this.label);
  final String label;
}
