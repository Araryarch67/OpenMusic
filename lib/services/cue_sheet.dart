import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/track.dart';

/// Splits whole-album rips (one FLAC/APE/WAV + a `.cue`) into their songs.
abstract final class CueSheet {
  /// Songs described by [cue], and the audio files they cover (which should
  /// not also be listed as one long track).
  static ({List<Track> tracks, Set<String> covers}) read(File cue) {
    final text = _decode(cue.readAsBytesSync());
    final dir = cue.parent.path;
    final now = DateTime.now().millisecondsSinceEpoch;

    String? albumTitle, albumArtist, file;
    final entries = <_Entry>[];
    _Entry? current;

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      final space = line.indexOf(' ');
      if (space < 0) continue;
      final cmd = line.substring(0, space).toUpperCase();
      final arg = line.substring(space + 1).trim();
      switch (cmd) {
        case 'FILE':
          file = _resolve(dir, _unquote(arg.substring(0, arg.lastIndexOf(' ') < 0 ? arg.length : arg.lastIndexOf(' '))));
        case 'TRACK':
          if (!arg.toUpperCase().endsWith('AUDIO') || file == null) {
            current = null;
          } else {
            current = _Entry(int.tryParse(arg.split(' ').first) ?? entries.length + 1, file);
            entries.add(current);
          }
        case 'TITLE':
          current == null ? albumTitle = _unquote(arg) : current.title = _unquote(arg);
        case 'PERFORMER':
          current == null ? albumArtist = _unquote(arg) : current.artist = _unquote(arg);
        case 'INDEX':
          final parts = arg.split(RegExp(r'\s+'));
          if (current != null && parts.length == 2 && int.tryParse(parts[0]) == 1) current.start = _time(parts[1]);
      }
    }

    final valid = entries.where((e) => e.start != null && File(e.file).existsSync()).toList();
    final tracks = <Track>[];
    for (var i = 0; i < valid.length; i++) {
      final e = valid[i];
      final next = i + 1 < valid.length && valid[i + 1].file == e.file ? valid[i + 1].start : null;
      final uri = Uri.file(e.file);
      tracks.add(
        Track(
          id: '$uri#cue${e.number}',
          uri: uri,
          title: e.title ?? 'Track ${e.number}',
          artist: e.artist ?? albumArtist ?? Track.unknownArtist,
          album: albumTitle,
          trackNumber: e.number,
          start: e.start,
          end: next,
          duration: next == null ? null : next - e.start!,
          addedAt: now,
          tagged: true,
        ),
      );
    }
    return (tracks: tracks, covers: {for (final e in valid) e.file});
  }

  /// Cue sheets are often in a legacy codepage; UTF-8 when it decodes, Latin-1 otherwise.
  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes).replaceFirst('﻿', '');
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  static String _unquote(String s) {
    final t = s.trim();
    return t.length >= 2 && t.startsWith('"') && t.endsWith('"') ? t.substring(1, t.length - 1) : t;
  }

  /// The FILE line often names the original `.wav` though the rip was later
  /// converted: fall back to any audio file with the same base name.
  static String _resolve(String dir, String name) {
    final exact = p.join(dir, name);
    if (File(exact).existsSync()) return exact;
    final base = p.basenameWithoutExtension(name);
    for (final ext in Track.audioExtensions) {
      final candidate = p.join(dir, '$base.$ext');
      if (File(candidate).existsSync()) return candidate;
    }
    return exact;
  }

  /// `MM:SS:FF`, 75 frames per second.
  static Duration? _time(String s) {
    final m = RegExp(r'^(\d+):(\d+):(\d+)$').firstMatch(s);
    if (m == null) return null;
    return Duration(
      milliseconds: int.parse(m[1]!) * 60000 + int.parse(m[2]!) * 1000 + (int.parse(m[3]!) * 1000 / 75).round(),
    );
  }
}

class _Entry {
  _Entry(this.number, this.file);

  final int number;
  final String file;
  String? title;
  String? artist;
  Duration? start;
}
