// Writes SACD images (Scarlet Book layout) for tests: a master TOC, area
// TOCs with track lists and text, and audio sectors packed the way discs
// pack them (frames split into packets across 2048-byte sectors, with time
// codes for the frames that start in each sector).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class IsoTrack {
  const IsoTrack(this.title, this.performer, this.frames);
  final String title;
  final String performer;

  /// One entry per 1/75 s frame: byte-interleaved DSD, or a DST frame.
  final List<Uint8List> frames;
}

class IsoArea {
  const IsoArea({required this.channels, required this.dst, required this.tracks});
  final int channels;
  final bool dst;
  final List<IsoTrack> tracks;
}

class _Sectors {
  final _data = BytesBuilder();
  int get next => _data.length ~/ 2048;

  void put(int lsn, List<int> sector) {
    if (lsn < next) throw StateError('sector $lsn written twice');
    while (next < lsn) {
      _data.add(Uint8List(2048));
    }
    final s = Uint8List(2048)..setRange(0, sector.length, sector);
    _data.add(s);
  }

  Uint8List bytes() => _data.toBytes();
}

Uint8List _sector(String id) => Uint8List(2048)..setAll(0, ascii.encode(id));

void _cstr(Uint8List b, int at, String s) => b.setAll(at, latin1.encode(s));

List<int> _time(int frames) => [frames ~/ 75 ~/ 60, frames ~/ 75 % 60, frames % 75];

/// Packs [area]'s frames into sectors from [lsn]. Returns the start sector of
/// each track and the sector after the last.
(List<int>, int) _writeAudio(_Sectors out, IsoArea area, int lsn) {
  final starts = <int>[];
  final frames = [for (final t in area.tracks) ...t.frames];
  final trackFirst = <int>{};
  var n = 0;
  for (final t in area.tracks) {
    trackFirst.add(n);
    n += t.frames.length;
  }
  var f = 0, off = 0; // frame being packed, bytes of it already written
  final infoSize = area.dst ? 4 : 3;
  while (f < frames.length) {
    final packets = <(bool, int)>[]; // (frame start, length)
    final infos = <int>[]; // time codes
    final payload = BytesBuilder();
    var pf = f, po = off;
    while (pf < frames.length && packets.length < 7) {
      final starting = po == 0;
      if (starting && infos.length == 7) break;
      final header = 1 + 2 * (packets.length + 1) + infoSize * (infos.length + (starting ? 1 : 0));
      final room = 2048 - header - payload.length;
      if (room < 16) break;
      final left = frames[pf].length - po;
      final len = [room, left, 2047].reduce((a, b) => a < b ? a : b);
      if (starting) {
        infos.add(pf);
        if (trackFirst.contains(pf)) starts.add(lsn);
      }
      packets.add((starting, len));
      payload.add(Uint8List.sublistView(frames[pf], po, po + len));
      po += len;
      if (po == frames[pf].length) {
        pf++;
        po = 0;
      }
    }
    final s = BytesBuilder()..addByte((packets.length << 5) | (infos.length << 2) | (area.dst ? 1 : 0));
    for (final (start, len) in packets) {
      s
        ..addByte((start ? 0x80 : 0) | (2 << 3) | (len >> 8))
        ..addByte(len & 0xFF);
    }
    for (final tc in infos) {
      s.add(_time(tc));
      if (area.dst) s.addByte(0);
    }
    s.add(payload.takeBytes());
    out.put(lsn++, s.takeBytes());
    f = pf;
    off = po;
  }
  return (starts, lsn);
}

Uint8List _areaToc(IsoArea area, List<int> starts, int end) {
  final toc = _sector(area.channels == 2 ? 'TWOCHTOC' : 'MULCHTOC');
  final v = ByteData.sublistView(toc);
  toc[8] = 1;
  toc[9] = 20;
  v.setUint16(10, 4); // sectors: TOC, TRL1, TRL2, TTxt
  v.setUint32(16, 2822400 ~/ 8 * area.channels);
  toc[20] = 4;
  toc[21] = area.dst ? 0 : 2;
  toc[32] = area.channels;
  toc[33] = area.channels == 2 ? 0 : (area.channels == 6 ? 4 : 3);
  toc[34] = area.channels;
  final total = area.tracks.fold<int>(0, (n, t) => n + t.frames.length);
  toc.setAll(64, _time(total));
  toc[69] = area.tracks.length;
  v.setUint32(72, starts.first);
  v.setUint32(76, end - 1);
  toc[80] = 1;
  _cstr(toc, 88, 'en');
  toc[90] = 2; // ISO 8859-1
  return toc;
}

/// Writes an image with [areas] (stereo first) to [path].
void writeSacdIso(String path, {required String album, required String artist, required List<IsoArea> areas}) {
  final out = _Sectors();
  // Audio first (its sectors are known only after packing), TOCs at fixed places.
  const tocLsn = [540, 560];
  var lsn = 600;
  final layouts = <(List<int>, int)>[];
  final audio = _Sectors();
  for (final a in areas) {
    final l = _writeAudio(audio, a, lsn);
    layouts.add(l);
    lsn = l.$2;
  }

  final mtoc = _sector('SACDMTOC');
  final mv = ByteData.sublistView(mtoc);
  mtoc[8] = 1;
  mtoc[9] = 20;
  mv.setUint16(16, 1);
  mv.setUint16(18, 1);
  for (var i = 0; i < areas.length; i++) {
    mv.setUint32(64 + i * 8, tocLsn[i]);
    mv.setUint16(84 + i * 2, 4);
  }
  mv.setUint16(120, 2026);
  mtoc[128] = 1;
  _cstr(mtoc, 136, 'en');
  mtoc[138] = 2;
  out.put(510, mtoc);
  for (var i = 0; i < 8; i++) {
    final text = _sector('SACDText');
    if (i == 0) {
      ByteData.sublistView(text)
        ..setUint16(16, 64)
        ..setUint16(18, 256);
      _cstr(text, 64, album);
      _cstr(text, 256, artist);
    }
    out.put(511 + i, text);
  }
  out.put(519, _sector('SACD_Man'));

  for (var i = 0; i < areas.length; i++) {
    final a = areas[i];
    final (starts, end) = layouts[i];
    out.put(tocLsn[i], _areaToc(a, starts, end));
    final trl1 = _sector('SACDTRL1');
    final trl2 = _sector('SACDTRL2');
    final ttxt = _sector('SACDTTxt');
    final v1 = ByteData.sublistView(trl1), vt = ByteData.sublistView(ttxt);
    var time = 0, textAt = 512;
    for (var t = 0; t < a.tracks.length; t++) {
      final track = a.tracks[t];
      final next = t + 1 < starts.length ? starts[t + 1] : end;
      v1
        ..setUint32(8 + t * 4, starts[t])
        ..setUint32(8 + 1020 + t * 4, next - starts[t]);
      trl2.setAll(8 + t * 4, _time(time));
      trl2.setAll(8 + 1020 + t * 4, _time(track.frames.length));
      time += track.frames.length;
      vt.setUint16(8 + t * 2, textAt);
      ttxt[textAt] = 2; // entries
      var p = textAt + 4;
      for (final (type, value) in [(1, track.title), (2, track.performer)]) {
        ttxt[p] = type;
        ttxt[p + 1] = 0x20;
        _cstr(ttxt, p + 2, value);
        p += 2 + latin1.encode(value).length + 1;
        p += p.isOdd ? 1 : 0; // zero padding between entries
      }
      textAt = p + 2;
    }
    out.put(tocLsn[i] + 1, trl1);
    out.put(tocLsn[i] + 2, trl2);
    out.put(tocLsn[i] + 3, ttxt);
  }
  final head = out.bytes();
  final image = BytesBuilder()
    ..add(head)
    ..add(Uint8List(600 * 2048 - head.length))
    ..add(Uint8List.sublistView(audio.bytes(), 600 * 2048));
  File(path).writeAsBytesSync(image.takeBytes());
}

/// [seconds] of a [hz] sine as byte-interleaved DSD64 frames (2nd-order
/// sigma-delta), the right channel an octave up.
List<Uint8List> dsdSineFrames({required double seconds, double hz = 1000, int channels = 2}) {
  const rate = 2822400;
  final frames = (seconds * 75).round();
  final out = <Uint8List>[];
  final i1 = List<double>.filled(channels, 0), i2 = List<double>.filled(channels, 0);
  final y = List<double>.filled(channels, 0);
  var n = 0;
  for (var f = 0; f < frames; f++) {
    final frame = Uint8List(4704 * channels);
    for (var b = 0; b < 4704; b++) {
      for (var c = 0; c < channels; c++) {
        var byte = 0;
        for (var bit = 0; bit < 8; bit++) {
          final t = (n + bit) / rate;
          final x = 0.5 * math.sin(2 * math.pi * hz * (c + 1) * t);
          i1[c] += x - y[c];
          i2[c] += i1[c] - y[c];
          y[c] = i2[c] >= 0 ? 1.0 : -1.0;
          byte = (byte << 1) | (y[c] > 0 ? 1 : 0);
        }
        frame[b * channels + c] = byte;
      }
      n += 8;
    }
    out.add(frame);
  }
  return out;
}
