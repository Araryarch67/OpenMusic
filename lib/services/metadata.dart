import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/track.dart';

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
        return (m.title, m.artist ?? m.albumArtist, m.album, m.duration, m.trackNumber);
      });
      return track.copyWith(
        title: _clean(tags.$1),
        artist: _clean(tags.$2),
        album: _clean(tags.$3),
        duration: tags.$4,
        trackNumber: tags.$5,
        tagged: true,
      );
    } catch (_) {
      return track.copyWith(tagged: true);
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

  static Future<Uint8List?> _networkArtwork(String? url) async {
    if (url == null) return null;
    try {
      final res = await http.get(Uri.parse(url));
      return res.statusCode == 200 ? res.bodyBytes : null;
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
