import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';

/// Editable tags of one file.
class TagEdit {
  TagEdit({this.title, this.artist, this.album, this.year, this.trackNumber, this.discNumber, this.genre});

  String? title;
  String? artist;
  String? album;
  int? year;
  int? trackNumber;
  int? discNumber;
  String? genre;

  /// New front cover (replaces every embedded picture); null keeps the current one.
  Uint8List? cover;
  String coverMime = 'image/jpeg';
}

/// Reads embedded tags / cover art off the UI thread and caches the results.
abstract final class Metadata {
  static const _maxCachedArtwork = 120;

  static final _artwork = <String, Uint8List?>{};
  static final _pendingArtwork = <String, Future<Uint8List?>>{};
  static final _accents = <String, Color>{};
  static final _pendingAccents = <String, Future<Color>>{};

  /// Returns [track] with title/artist/album/duration filled from its tags.
  static Future<Track> enrich(Track track) async {
    final path = track.path;
    if (path == null) return track.copyWith(tagged: true);
    try {
      final tags = await Isolate.run(() {
        final m = readMetadata(File(path));
        return (m.title, m.artist ?? m.albumArtist, m.album, m.duration, m.trackNumber, m.discNumber);
      });
      return track.copyWith(
        title: _clean(tags.$1),
        artist: _clean(tags.$2),
        album: _clean(tags.$3),
        duration: tags.$4,
        trackNumber: tags.$5,
        discNumber: tags.$6,
        tagged: true,
      );
    } catch (_) {
      return track.copyWith(tagged: true);
    }
  }

  /// FLAC is written in-process (the bundled writer keeps every other tag).
  /// Other formats go through the `ffmpeg` command when it is installed: a
  /// stream copy that only changes the tags it is told to.
  ///
  /// Not MP4/M4A: ffmpeg's MP4 muxer keeps only the iTunes tags it knows, so
  /// ReplayGain and other freeform tags would be lost.
  static const _ffmpegWritable = {'mp3', 'ogg', 'oga', 'opus', 'wav', 'aiff', 'aif', 'wv', 'mka'};

  /// Formats where ffmpeg can also replace the embedded cover.
  static const _ffmpegCover = {'mp3'};

  static bool _ffmpeg = false;

  /// Looks for `ffmpeg` once at startup so [canEditTags] can answer synchronously.
  static Future<void> probeTagTools() async {
    try {
      _ffmpeg = (await Process.run('ffmpeg', ['-hide_banner', '-version'])).exitCode == 0;
    } catch (_) {
      _ffmpeg = false;
    }
  }

  static String _ext(String path) => path.split('.').last.toLowerCase();

  static bool canEditTags(Track t) {
    final path = t.path;
    if (path == null || t.isCueTrack) return false;
    final ext = _ext(path);
    return ext == 'flac' || (_ffmpeg && _ffmpegWritable.contains(ext));
  }

  /// Whether "Change cover" can be offered for [t].
  static bool canEditCover(Track t) => _ext(t.path!) == 'flac' || _ffmpegCover.contains(_ext(t.path!));

  static Future<TagEdit> readTags(Track track) {
    final path = track.path!;
    return Isolate.run(() {
      final m = readMetadata(File(path));
      return TagEdit(
        title: m.title,
        artist: m.artist,
        album: m.album,
        year: m.year?.year,
        trackNumber: m.trackNumber,
        discNumber: m.discNumber,
        genre: m.genres.firstOrNull,
      );
    });
  }

  /// Writes [edit] into the file, safely: the change is made on a copy, which
  /// must come out readable before it replaces the original.
  static Future<Track> writeTags(Track track, TagEdit edit) async {
    final path = track.path!;
    final dot = path.lastIndexOf('.');
    final temp = File('${path.substring(0, dot)}.openmusic-tmp${path.substring(dot)}');
    try {
      if (_ext(path) == 'flac') {
        await Isolate.run(() => _writeFlac(path, temp, edit));
      } else {
        await _writeWithFfmpeg(path, temp, edit);
      }
      await temp.rename(path);
    } finally {
      if (temp.existsSync()) temp.deleteSync();
    }
    _artwork.remove(_artKey(track));
    _accents.remove(_artKey(track));
    final updated = await enrich(track.copyWith(tagged: false));
    _artwork.remove(_artKey(updated));
    _accents.remove(_artKey(updated));
    return updated;
  }

  static void _writeFlac(String path, File temp, TagEdit edit) {
    File(path).copySync(temp.path);
    updateMetadata(temp, (m) {
      m.setTitle(edit.title);
      m.setArtist(edit.artist);
      m.setAlbum(edit.album);
      m.setYear(edit.year == null ? null : DateTime(edit.year!));
      m.setTrackNumber(edit.trackNumber);
      if (m case final VorbisMetadata v) v.discNumber = edit.discNumber;
      m.setGenres([?edit.genre]);
      if (edit.cover != null) m.setPictures([Picture(edit.cover!, edit.coverMime, PictureType.coverFront)]);
    });
    final check = readMetadata(temp);
    if (check.title != edit.title || check.discNumber != edit.discNumber) {
      throw const FileSystemException('The new info didn\'t save correctly; the file was left as it was');
    }
  }

  static Future<void> _writeWithFfmpeg(String path, File temp, TagEdit edit) async {
    final cover = edit.cover != null && _ffmpegCover.contains(_ext(path));
    File? coverFile;
    if (cover) {
      coverFile = File('${temp.path}.${edit.coverMime == 'image/png' ? 'png' : 'jpg'}')..writeAsBytesSync(edit.cover!);
    }
    // Ogg keeps its tags (Vorbis comments) on the audio stream, not the file.
    final scope = const {'ogg', 'oga', 'opus'}.contains(_ext(path)) ? ':s:a:0' : '';
    try {
      final r = await Process.run('ffmpeg', [
        '-hide_banner', '-loglevel', 'error', '-y', '-i', path, //
        if (cover) ...['-i', coverFile!.path, '-map', '0', '-map', '-0:v?', '-map', '1'] else ...['-map', '0'],
        '-c', 'copy', '-map_metadata', '0',
        for (final (key, value) in [
          ('title', edit.title),
          ('artist', edit.artist),
          ('album', edit.album),
          ('date', edit.year),
          ('track', edit.trackNumber),
          ('disc', edit.discNumber),
          ('genre', edit.genre),
        ]) ...['-metadata$scope', '$key=${value ?? ''}'],
        if (cover) ...['-disposition:v:0', 'attached_pic'],
        if (_ext(path) == 'mp3') ...['-id3v2_version', '3'],
        temp.path,
      ]);
      if (r.exitCode != 0 || !temp.existsSync() || temp.lengthSync() == 0) {
        throw FileSystemException('Couldn\'t write the new info: ${(r.stderr as String).trim()}');
      }
    } finally {
      if (coverFile != null && coverFile.existsSync()) coverFile.deleteSync();
    }
  }

  static String? _clean(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  /// Artwork already in memory, so widgets can paint it on the first frame.
  static Uint8List? cachedArtwork(Track track) => _artwork[_artKey(track)];

  static bool hasCachedArtwork(Track track) => _artwork.containsKey(_artKey(track));

  /// Tracks on the same album share one cover lookup.
  static String _artKey(Track t) => t.albumKey ?? t.id;

  static Future<Uint8List?> artwork(Track track) {
    final key = _artKey(track);
    if (_artwork.containsKey(key)) return Future.value(_artwork[key]);
    return _pendingArtwork[key] ??= _loadArtwork(track).then((bytes) {
      _pendingArtwork.remove(key);
      _artwork[key] = bytes;
      if (_artwork.length > _maxCachedArtwork) _artwork.remove(_artwork.keys.first);
      return bytes;
    });
  }

  static Future<Uint8List?> _loadArtwork(Track track) async {
    final path = track.path;
    if (path == null) return _networkArtwork(track.artworkUrl);
    try {
      return await Isolate.run(() => _embeddedPicture(path) ?? _sidecarImage(path));
    } catch (_) {
      return null;
    }
  }

  /// One connection pool for every cover: a fresh client per image would pay
  /// a TLS handshake each time.
  static final _artHttp = http.Client();

  /// Covers of YouTube songs, kept on disk so the next launch paints them
  /// without the network. Null where there is no cache folder (tests).
  static final Future<Directory?> _artDir = () async {
    try {
      final dir = Directory('${(await getApplicationCacheDirectory()).path}${Platform.pathSeparator}artwork');
      await dir.create(recursive: true);
      _pruneArtCache(dir).ignore();
      return dir;
    } catch (_) {
      return null;
    }
  }();

  /// Keeps the newest few thousand covers (each ~20-60 KB).
  static Future<void> _pruneArtCache(Directory dir, {int keep = 3000}) async {
    final files = await dir.list().where((e) => e is File).cast<File>().toList();
    if (files.length <= keep) return;
    final dated = [for (final f in files) (f, (await f.stat()).modified)]..sort((a, b) => b.$2.compareTo(a.$2));
    for (final (f, _) in dated.skip(keep)) {
      f.delete().ignore();
    }
  }

  static Future<Uint8List?> _networkArtwork(String? url) async {
    if (url == null) return null;
    final dir = await _artDir;
    final file = dir == null ? null : File('${dir.path}${Platform.pathSeparator}${sha1.convert(url.codeUnits)}');
    try {
      if (file != null && await file.exists()) return await file.readAsBytes();
    } catch (_) {}
    try {
      final res = await _artHttp.get(Uri.parse(url));
      if (res.statusCode != 200) return null;
      if (file != null) {
        // Written aside and renamed, so a half-written cover never gets read.
        final part = File('${file.path}.part');
        part.writeAsBytes(res.bodyBytes).then((_) => part.rename(file.path)).ignore();
      }
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _embeddedPicture(String path) {
    try {
      final pictures = readMetadata(File(path), getImage: true).pictures;
      if (pictures.isEmpty) return null;
      final front = pictures.where((p) => p.pictureType == PictureType.coverFront);
      return (front.isEmpty ? pictures.first : front.first).bytes;
    } catch (_) {
      return null;
    }
  }

  /// `song.jpg` next to `song.m4a` (YouTube imports), then the usual folder art names.
  static Uint8List? _sidecarImage(String path) {
    final dir = File(path).parent.path;
    final stem = path.substring(0, path.lastIndexOf('.'));
    final candidates = [
      for (final ext in ['jpg', 'jpeg', 'png', 'webp']) '$stem.$ext',
      for (final name in ['cover', 'folder', 'front', 'Cover', 'Folder', 'Front'])
        for (final ext in ['jpg', 'png']) '$dir${Platform.pathSeparator}$name.$ext',
    ];
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.readAsBytesSync();
    }
    return null;
  }

  /// Neutral grey for anything without cover art.
  static const fallbackAccent = Color(0xFF535353);

  static Color? cachedAccent(Track track) => _accents[_artKey(track)];

  /// A punchy colour sampled from the cover art, for gradients and the mini player.
  static Future<Color> accent(Track track) {
    final key = _artKey(track);
    final cached = _accents[key];
    if (cached != null) return Future.value(cached);
    return _pendingAccents[key] ??= () async {
      final bytes = await artwork(track);
      final color = (bytes == null ? null : await _averageColor(bytes)) ?? fallbackAccent;
      _pendingAccents.remove(key);
      return _accents[key] = color;
    }();
  }

  static Future<Color?> _averageColor(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 16, targetHeight: 16);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      if (data == null) return null;
      var r = 0, g = 0, b = 0, n = 0;
      for (var i = 0; i < data.lengthInBytes; i += 4) {
        r += data.getUint8(i);
        g += data.getUint8(i + 1);
        b += data.getUint8(i + 2);
        n++;
      }
      final hsl = HSLColor.fromColor(Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n));
      // Keep it rich enough to read as a colour against black, but never neon.
      return hsl
          .withSaturation(hsl.saturation.clamp(0.35, 0.8))
          .withLightness(hsl.lightness.clamp(0.3, 0.45))
          .toColor();
    } catch (_) {
      return null;
    }
  }
}
