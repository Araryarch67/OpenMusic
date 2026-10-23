// StreamAudioSource/Response are just_audio's documented way to feed custom
// byte streams (see youtube_audio_source.dart).
// ignore_for_file: experimental_member_use

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import '../models/track.dart';
import 'dop.dart';

/// SACD audio runs at 75 frames a second; a DSD64 frame holds 4704 bytes
/// (37632 one-bit samples) per channel.
const sacdFramesPerSecond = 75;
const sacdDsdFrameBytes = 4704;
const _sacdBitRate = 2822400;

/// A song on an SACD image.
class SacdTrack {
  const SacdTrack({
    required this.number,
    required this.title,
    this.performer,
    required this.startFrame,
    required this.frames,
    required this.startLsn,
    required this.endLsn,
  });

  /// 1-based, as printed on the sleeve.
  final int number;
  final String title;
  final String? performer;

  /// Area time (frames since the area's start) where the song begins.
  final int startFrame;
  final int frames;

  /// Sectors holding the song: it starts in [startLsn]; the last of its
  /// frames ends before [endLsn].
  final int startLsn;
  final int endLsn;

  Duration get duration => Duration(microseconds: frames * 1000000 ~/ sacdFramesPerSecond);
}

/// The stereo or multichannel programme of a disc.
class SacdArea {
  const SacdArea({required this.channels, required this.dst, required this.tracks});

  final int channels;

  /// Compressed with DST (lossless): needs FFmpeg's DST decoder, no DoP.
  final bool dst;
  final List<SacdTrack> tracks;

  int get frameBytes => sacdDsdFrameBytes * channels;
}

/// What an SACD ISO holds, read from its tables of contents (Scarlet Book).
class SacdDisc {
  SacdDisc._({
    required this.path,
    required this.sectorSize,
    this.albumTitle,
    this.albumArtist,
    this.year,
    this.stereo,
    this.multichannel,
  });

  final String path;

  /// 2048 for a plain image; 2064 for raw dumps with a 12-byte header (and
  /// 4 trailing bytes) per sector.
  final int sectorSize;
  final String? albumTitle;
  final String? albumArtist;
  final int? year;
  final SacdArea? stereo;
  final SacdArea? multichannel;

  /// Stereo when the disc has it: what nearly every listener sets up for.
  SacdArea get area => (stereo ?? multichannel)!;

  int get _dataOffset => sectorSize == 2048 ? 0 : 12;

  static const _masterToc = 510;

  /// Null when [path] isn't an SACD image (a DVD or data ISO, say).
  static SacdDisc? read(String path) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      for (final size in const [2048, 2064]) {
        final skip = size == 2048 ? 0 : 12;
        f.setPositionSync(_masterToc * size + skip);
        if (ascii.decode(f.readSync(8), allowInvalid: true) == 'SACDMTOC') return _read(path, f, size);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      f?.closeSync();
    }
  }

  static Uint8List _sectors(RandomAccessFile f, int size, int lsn, int count) {
    final skip = size == 2048 ? 0 : 12;
    if (size == 2048) {
      f.setPositionSync(lsn * size);
      return f.readSync(count * size);
    }
    final out = BytesBuilder();
    for (var i = 0; i < count; i++) {
      f.setPositionSync((lsn + i) * size + skip);
      out.add(f.readSync(2048));
    }
    return out.takeBytes();
  }

  static SacdDisc? _read(String path, RandomAccessFile f, int size) {
    final master = _sectors(f, size, _masterToc, 2);
    final m = ByteData.sublistView(master);
    final charset = master[136 + 2] & 7; // first locale's character set
    String? text(Uint8List block, int pos) => pos == 0 ? null : _string(block, pos, charset);

    String? albumTitle, albumArtist;
    final t = Uint8List.sublistView(master, 2048);
    if (ascii.decode(t.sublist(0, 8), allowInvalid: true) == 'SACDText') {
      final tv = ByteData.sublistView(t);
      albumTitle = text(t, tv.getUint16(16)) ?? text(t, tv.getUint16(32));
      albumArtist = text(t, tv.getUint16(18)) ?? text(t, tv.getUint16(34));
    }
    final year = m.getUint16(120);
    SacdArea? stereo, multi;
    for (final (start, length) in [(m.getUint32(64), m.getUint16(84)), (m.getUint32(72), m.getUint16(86))]) {
      if (start == 0 || length == 0) continue;
      final area = _area(_sectors(f, size, start, length), charset);
      if (area == null) continue;
      if (area.channels == 2 && stereo == null) {
        stereo = area;
      } else {
        multi ??= area;
      }
    }
    if (stereo == null && multi == null) return null;
    return SacdDisc._(
      path: path,
      sectorSize: size,
      albumTitle: albumTitle,
      albumArtist: albumArtist,
      year: year == 0 ? null : year,
      stereo: stereo,
      multichannel: multi,
    );
  }

  static SacdArea? _area(Uint8List data, int masterCharset) {
    final id = ascii.decode(data.sublist(0, 8), allowInvalid: true);
    if (id != 'TWOCHTOC' && id != 'MULCHTOC') return null;
    final v = ByteData.sublistView(data);
    final frameFormat = data[21] & 0x0F;
    final channels = data[32];
    final count = data[69];
    final trackStart = v.getUint32(72);
    final trackEnd = v.getUint32(76);
    final charset = data[88 + 2] & 7;
    if (channels == 0 || count == 0) return null;

    final starts = List<int>.filled(count, 0), lengths = List<int>.filled(count, 0);
    final startLsn = List<int>.filled(count, 0);
    final titles = List<String?>.filled(count, null), performers = List<String?>.filled(count, null);
    for (var at = 2048; at + 2048 <= data.length; at += 2048) {
      final s = Uint8List.sublistView(data, at, at + 2048);
      final sv = ByteData.sublistView(s);
      switch (ascii.decode(s.sublist(0, 8), allowInvalid: true)) {
        case 'SACDTRL1':
          for (var i = 0; i < count; i++) {
            startLsn[i] = sv.getUint32(8 + i * 4);
          }
        case 'SACDTRL2':
          int frames(int o) => (s[o] * 60 + s[o + 1]) * sacdFramesPerSecond + s[o + 2];
          for (var i = 0; i < count; i++) {
            starts[i] = frames(8 + i * 4);
            lengths[i] = frames(8 + 255 * 4 + i * 4);
          }
        case 'SACDTTxt' when titles.every((t) => t == null):
          for (var i = 0; i < count; i++) {
            final pos = sv.getUint16(8 + i * 2);
            if (pos == 0 || pos >= s.length) continue;
            // An entry count, 3 reserved bytes, then (type, 0x20?, text\0, padding) per entry.
            final entries = s[pos];
            var p = pos + 4;
            for (var e = 0; e < entries && p + 2 < s.length; e++) {
              final type = s[p];
              p += 2;
              final value = _string(s, p, charset == 0 ? masterCharset : charset);
              if (type == 0x01) titles[i] = value;
              if (type == 0x02) performers[i] = value;
              while (p < s.length && s[p] != 0) {
                p++;
              }
              while (p < s.length && s[p] == 0) {
                p++;
              }
            }
          }
      }
    }
    if (lengths.every((l) => l == 0)) return null;
    return SacdArea(
      channels: channels,
      dst: frameFormat == 0,
      tracks: [
        for (var i = 0; i < count; i++)
          SacdTrack(
            number: i + 1,
            title: titles[i] ?? 'Track ${i + 1}',
            performer: performers[i],
            startFrame: starts[i],
            frames: lengths[i],
            startLsn: i == 0 ? trackStart : startLsn[i],
            // A song's last frame may end in the sector where the next begins.
            endLsn: i + 1 < count ? startLsn[i + 1] + 1 : trackEnd + 1,
          ),
      ],
    );
  }

  /// Text in the disc's character set. ISO 646 and Latin-1 are decoded;
  /// Japanese, Korean and Chinese sets fall back to Latin-1 (garbled, but
  /// rare outside their home markets).
  static String? _string(Uint8List b, int at, int charset) {
    var end = at;
    while (end < b.length && b[end] != 0) {
      end++;
    }
    if (end == at) return null;
    final bytes = b.sublist(at, end);
    final s = charset == 1 ? ascii.decode(bytes, allowInvalid: true) : latin1.decode(bytes);
    final trimmed = s.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Library songs for the preferred area; the ISO's path with `#sacd<n>`
  /// tells them apart.
  List<Track> tracks() {
    final uri = Uri.file(path);
    final a = area;
    return [
      for (final t in a.tracks)
        Track(
          id: '$uri#sacd${t.number}',
          uri: uri,
          title: t.title,
          artist: t.performer ?? albumArtist ?? Track.unknownArtist,
          album: albumTitle,
          duration: t.duration,
          trackNumber: t.number,
          start: Duration(microseconds: t.startFrame * 1000000 ~/ sacdFramesPerSecond),
          end: Duration(microseconds: (t.startFrame + t.frames) * 1000000 ~/ sacdFramesPerSecond),
          addedAt: DateTime.now().millisecondsSinceEpoch,
          tagged: true,
        ),
    ];
  }

  static final _discs = <String, (DateTime, int, SacdDisc?)>{};

  /// [read], remembered while the image is unchanged: every queued song of
  /// a disc asks for it, on the UI thread, and the tables of contents can
  /// be hundreds of kilobytes.
  static SacdDisc? _cached(String path) {
    try {
      final st = File(path).statSync();
      final hit = _discs[path];
      if (hit != null && hit.$1 == st.modified && hit.$2 == st.size) return hit.$3;
      final disc = read(path);
      _discs[path] = (st.modified, st.size, disc);
      if (_discs.length > 8) _discs.remove(_discs.keys.first);
      return disc;
    } catch (_) {
      return null;
    }
  }

  /// The song a library track (from [tracks]) refers to.
  static (SacdDisc, SacdTrack)? find(Track t) {
    final path = t.path;
    final m = RegExp(r'#sacd(\d+)$').firstMatch(t.id);
    if (path == null || m == null) return null;
    final disc = _cached(path);
    final number = int.parse(m[1]!);
    final track = disc?.area.tracks.where((x) => x.number == number).firstOrNull;
    return track == null ? null : (disc!, track);
  }

  static bool isSacdTrack(Track t) => RegExp(r'#sacd\d+$').hasMatch(t.id);
}

/// One audio sector, parsed: where each packet's bytes are and which frames
/// start in it (by area time).
class _Sector {
  _Sector(Uint8List s) : dst = s[0] & 1 == 1 {
    final packets = s[0] >> 5;
    final frameInfos = (s[0] >> 2) & 7;
    var o = 1;
    for (var i = 0; i < packets; i++) {
      starts.add(s[o] >> 7 == 1);
      types.add((s[o] >> 3) & 7);
      lengths.add(((s[o] & 7) << 8) | s[o + 1]);
      o += 2;
    }
    for (var i = 0; i < frameInfos; i++) {
      timecodes.add((s[o] * 60 + s[o + 1]) * sacdFramesPerSecond + s[o + 2]);
      o += dst ? 4 : 3;
    }
    dataStart = o;
  }

  final bool dst;
  final starts = <bool>[];
  final types = <int>[];
  final lengths = <int>[];
  final timecodes = <int>[];
  late final int dataStart;
}

/// Reads one song's audio frames (DSD or DST) out of the image.
class SacdFrameReader {
  SacdFrameReader(this.disc, this.track);

  final SacdDisc disc;
  final SacdTrack track;

  /// Sectors read per file access while streaming (128 KB).
  static const _batch = 64;

  Future<Uint8List> _sectorsAt(RandomAccessFile f, int lsn, int count) async {
    final size = disc.sectorSize;
    if (size == 2048) {
      await f.setPosition(lsn * size);
      return f.read(count * size);
    }
    await f.setPosition(lsn * size);
    final raw = await f.read(count * size);
    final out = Uint8List(raw.length ~/ size * 2048);
    for (var i = 0; i < out.length ~/ 2048; i++) {
      out.setRange(i * 2048, i * 2048 + 2048, raw, i * size + disc._dataOffset);
    }
    return out;
  }

  /// The first frame starting at or after [lsn] (within a few sectors) and
  /// the sector it starts in.
  Future<(int, int)?> _firstFrameFrom(RandomAccessFile f, int lsn) async {
    final s = await _sectorsAt(f, lsn, 16);
    for (var i = 0; i * 2048 < s.length; i++) {
      final sector = _Sector(Uint8List.sublistView(s, i * 2048, i * 2048 + 2048));
      if (sector.timecodes.isNotEmpty) return (sector.timecodes.first, lsn + i);
    }
    return null;
  }

  /// The sector to start reading at to get frame [frame] of the song: found
  /// by bisecting on the frames' time codes.
  Future<int> _locate(RandomAccessFile f, int target) async {
    var lo = track.startLsn, hi = track.endLsn;
    var best = track.startLsn;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      final found = await _firstFrameFrom(f, mid);
      if (found == null || found.$1 > target) {
        hi = mid;
      } else {
        best = found.$2;
        lo = mid + 1;
      }
    }
    return best;
  }

  /// Frames [from, from + count) of the song, each as its raw bytes:
  /// byte-interleaved DSD ([SacdArea.frameBytes] long) or a DST frame.
  Stream<Uint8List> frames(int from, int count) async* {
    count = math.min(count, track.frames - from);
    if (count <= 0) return;
    final f = await File(disc.path).open();
    try {
      final first = track.startFrame + from;
      final end = first + count;
      var lsn = await _locate(f, first);
      final frame = BytesBuilder(copy: false);
      int? current; // time code of the frame being assembled
      var next = first;
      while (next < end && lsn < track.endLsn + 16) {
        final block = await _sectorsAt(f, lsn, _batch);
        if (block.isEmpty) break;
        for (var i = 0; i * 2048 < block.length && next < end; i++) {
          final bytes = Uint8List.sublistView(block, i * 2048, i * 2048 + 2048);
          final s = _Sector(bytes);
          var o = s.dataStart;
          var k = 0; // index into the sector's time codes
          for (var p = 0; p < s.types.length; p++) {
            final len = s.lengths[p];
            if (s.types[p] == 2) {
              if (s.starts[p]) {
                if (current != null && current >= first && frame.length > 0) {
                  yield frame.takeBytes();
                  next = current + 1;
                  if (next >= end) break;
                }
                frame.clear();
                current = k < s.timecodes.length ? s.timecodes[k] : (current ?? first - 1) + 1;
                k++;
              }
              if (current != null && current >= first && o + len <= bytes.length) {
                frame.add(Uint8List.sublistView(bytes, o, o + len));
              }
            }
            o += len;
          }
        }
        lsn += _batch;
      }
      if (next < end && current != null && current >= first && frame.length > 0) yield frame.takeBytes();
    } finally {
      await f.close();
    }
  }
}

/// Bytes of a DSDIFF file built on the fly around an SACD song, which mpv
/// (FFmpeg) decodes like any .dff, DST included.
///
/// Every frame gets the same number of bytes, so a byte offset maps straight
/// to a frame: plain DSD frames are fixed-size anyway, and each DST frame is
/// followed by a filler chunk (FFmpeg skips chunks it doesn't know) up to the
/// largest size a DST frame can have.
class SacdAudioSource extends StreamAudioSource {
  SacdAudioSource(this.disc, this.track, {super.tag}) : reader = SacdFrameReader(disc, track) {
    _header = _buildHeader();
  }

  final SacdDisc disc;
  final SacdTrack track;
  final SacdFrameReader reader;
  late final Uint8List _header;

  SacdArea get _area => disc.area;

  /// DST frames are at most a DSD frame plus a byte (stored uncompressed).
  int get _dstMax => (_area.frameBytes + 2) & ~1;

  /// Bytes per frame in the file.
  int get slot => _area.dst ? 12 + _dstMax + 12 + 2 : _area.frameBytes;

  int get length => _header.length + track.frames * slot;

  static const _channelIds = {
    2: ['SLFT', 'SRGT'],
    5: ['MLFT', 'MRGT', 'C   ', 'LS  ', 'RS  '],
    6: ['MLFT', 'MRGT', 'C   ', 'LFE ', 'LS  ', 'RS  '],
  };

  Uint8List _buildHeader() {
    final a = _area;
    final b = BytesBuilder();
    void id(String s) => b.add(ascii.encode(s));
    void u64(int v) => b.add((ByteData(8)..setUint64(0, v)).buffer.asUint8List());
    void u32(int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
    void u16(int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
    final name = a.dst ? 'DST Encoded' : 'not compressed';
    final pstring = [name.length, ...ascii.encode(name), if ((name.length + 1).isOdd) 0];
    final ids = _channelIds[a.channels] ?? [for (var i = 0; i < a.channels; i++) 'C${i.toString().padLeft(3, '0')}'];
    final propSize = 4 + (12 + 4) + (12 + 2 + 4 * a.channels) + (12 + 4 + pstring.length);
    final body = track.frames * slot;
    final bodyChunk = a.dst ? 12 + (12 + 6) + body : 12 + body;
    final total = 4 + (12 + 4) + (12 + propSize) + bodyChunk;
    id('FRM8');
    u64(total);
    id('DSD ');
    id('FVER');
    u64(4);
    u32(0x01050000);
    id('PROP');
    u64(propSize);
    id('SND ');
    id('FS  ');
    u64(4);
    u32(_sacdBitRate);
    id('CHNL');
    u64(2 + 4 * a.channels);
    u16(a.channels);
    ids.forEach(id);
    id('CMPR');
    u64(4 + pstring.length);
    id(a.dst ? 'DST ' : 'DSD ');
    b.add(pstring);
    if (a.dst) {
      id('DST ');
      u64((12 + 6) + body);
      id('FRTE');
      u64(6);
      u32(track.frames);
      u16(sacdFramesPerSecond);
    } else {
      id('DSD ');
      u64(body);
    }
    return b.takeBytes();
  }

  /// One frame's slot: the DSD bytes, or a DST frame chunk plus filler.
  Uint8List _slot(Uint8List frame) {
    if (!_area.dst) {
      if (frame.length == slot) return frame;
      // A damaged frame: silence keeps the timing.
      return Uint8List(slot)..fillRange(0, slot, 0x69);
    }
    final out = Uint8List(slot);
    final v = ByteData.sublistView(out);
    final len = math.min(frame.length, _dstMax);
    out.setAll(0, ascii.encode('DSTF'));
    v.setUint64(4, len);
    out.setRange(12, 12 + len, frame);
    final filler = 12 + len + (len & 1);
    out.setAll(filler, ascii.encode('FILL'));
    v.setUint64(filler + 4, slot - filler - 12);
    return out;
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = (end ?? length).clamp(from, length);
    return StreamAudioResponse(
      sourceLength: length,
      contentLength: to - from,
      offset: from,
      contentType: 'audio/x-dff',
      stream: bytes(from, to),
    );
  }

  /// Bytes [from, to) of the file.
  Stream<Uint8List> bytes(int from, int to) async* {
    final h = _header.length;
    if (from < h) {
      yield Uint8List.sublistView(_header, from, math.min(to, h));
      from = h;
    }
    if (from >= to) return;
    final first = (from - h) ~/ slot;
    var skip = (from - h) % slot;
    final last = (to - h + slot - 1) ~/ slot;
    var left = to - from;
    var produced = first;
    await for (final frame in reader.frames(first, last - first)) {
      final s = _slot(frame);
      final take = math.min(s.length - skip, left);
      yield Uint8List.sublistView(s, skip, skip + take);
      left -= take;
      skip = 0;
      produced++;
      if (left <= 0) return;
    }
    // Frames the image didn't give (damage): silence, so the length holds.
    while (left > 0 && produced < last) {
      final s = _slot(Uint8List(0));
      final take = math.min(s.length - skip, left);
      yield Uint8List.sublistView(s, skip, skip + take);
      left -= take;
      skip = 0;
      produced++;
    }
  }
}

/// A plain-DSD SACD song as DSD bytes, for DoP.
class SacdDsd implements DsdSource {
  SacdDsd(this.disc, this.track) : reader = SacdFrameReader(disc, track);

  final SacdDisc disc;
  final SacdTrack track;
  final SacdFrameReader reader;

  @override
  int get channels => disc.area.channels;

  @override
  int get bitRate => _sacdBitRate;

  @override
  int get bytesPerChannel => track.frames * sacdDsdFrameBytes;

  @override
  Future<Uint8List> interleaved(int byteFrom, int count) async {
    final out = Uint8List(count * channels)..fillRange(0, count * channels, 0x69);
    final firstFrame = byteFrom ~/ sacdDsdFrameBytes;
    final lastFrame = (byteFrom + count - 1) ~/ sacdDsdFrameBytes;
    var frameIndex = firstFrame;
    await for (final frame in reader.frames(firstFrame, lastFrame - firstFrame + 1)) {
      // Frame bytes are interleaved already; copy the overlap.
      final frameStart = frameIndex * sacdDsdFrameBytes;
      final a = math.max(byteFrom, frameStart), b = math.min(byteFrom + count, frameStart + sacdDsdFrameBytes);
      if (b > a && frame.length >= (b - frameStart) * channels) {
        out.setRange((a - byteFrom) * channels, (b - byteFrom) * channels, frame, (a - frameStart) * channels);
      }
      frameIndex++;
    }
    return out;
  }
}
