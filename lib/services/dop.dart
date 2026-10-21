// StreamAudioSource/Response are just_audio's documented way to feed custom
// byte streams (see youtube_audio_source.dart).
// ignore_for_file: experimental_member_use

import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// Where the 1-bit audio sits in a DSF or DSDIFF file.
class DsdFile {
  const DsdFile._({
    required this.path,
    required this.channels,
    required this.bitRate,
    required this.bytesPerChannel,
    required this.dataOffset,
    required this.blockSize,
    required this.lsbFirst,
  });

  final String path;
  final int channels;

  /// 1-bit samples per second per channel: 2822400 for DSD64.
  final int bitRate;

  /// Audio bytes per channel (8 samples each), padding left out.
  final int bytesPerChannel;
  final int dataOffset;

  /// DSF stores each channel in blocks of this many bytes; 0 for DSDIFF,
  /// which interleaves single bytes.
  final int blockSize;

  /// DSF usually keeps the oldest sample in the lowest bit; DoP wants it highest.
  final bool lsbFirst;

  /// 64 for DSD64, 128 for DSD128...
  int get multiple => bitRate ~/ 44100;

  /// The PCM rate DoP runs at: 16 DSD samples per PCM frame.
  int get dopRate => bitRate ~/ 16;

  /// DoP frames (two DSD bytes per channel each).
  int get frames => bytesPerChannel ~/ 2;

  Duration get duration => Duration(microseconds: bytesPerChannel * 8 * 1000000 ~/ bitRate);

  static bool isDsdPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ext == 'dsf' || ext == 'dff';
  }

  /// Reads the headers; null when the file isn't plain (uncompressed) DSD.
  static DsdFile? read(String path) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      final head = f.readSync(4);
      if (head.length < 4) return null;
      final magic = String.fromCharCodes(head);
      if (magic == 'DSD ') return _dsf(path, f);
      if (magic == 'FRM8') return _dff(path, f);
      return null;
    } catch (_) {
      return null;
    } finally {
      f?.closeSync();
    }
  }

  static DsdFile? _dsf(String path, RandomAccessFile f) {
    // DSD chunk (28 bytes), then "fmt " (52), then "data" (12 + audio). Little-endian.
    f.setPositionSync(0);
    final b = ByteData.sublistView(f.readSync(28 + 52 + 12));
    if (b.lengthInBytes < 92) return null;
    final fmt = 28;
    if (String.fromCharCodes(b.buffer.asUint8List(b.offsetInBytes + fmt, 4)) != 'fmt ') return null;
    final formatId = b.getUint32(fmt + 16, Endian.little);
    final channels = b.getUint32(fmt + 24, Endian.little);
    final rate = b.getUint32(fmt + 28, Endian.little);
    final bits = b.getUint32(fmt + 32, Endian.little);
    final samples = b.getUint64(fmt + 36, Endian.little);
    final block = b.getUint32(fmt + 44, Endian.little);
    final data = fmt + b.getUint32(fmt + 4, Endian.little); // the fmt chunk's own size
    if (formatId != 0 || channels == 0 || block == 0 || rate % 44100 != 0) return null;
    return DsdFile._(
      path: path,
      channels: channels,
      bitRate: rate,
      bytesPerChannel: (samples + 7) ~/ 8,
      dataOffset: data + 12,
      blockSize: block,
      lsbFirst: bits == 1,
    );
  }

  static DsdFile? _dff(String path, RandomAccessFile f) {
    // FRM8 > PROP("SND ") > FS / CHNL / CMPR, then the "DSD " chunk. Big-endian, 64-bit sizes.
    final length = f.lengthSync();
    int? rate, channels, dataOffset, dataBytes;
    var compressed = false;
    void chunks(int from, int to) {
      var at = from;
      while (at + 12 <= to) {
        f.setPositionSync(at);
        final h = f.readSync(12);
        if (h.length < 12) return;
        final id = String.fromCharCodes(h.sublist(0, 4));
        final size = ByteData.sublistView(h).getUint64(4);
        final body = at + 12;
        switch (id) {
          case 'PROP':
            chunks(body + 4, body + size); // after "SND "
          case 'FS  ':
            rate = ByteData.sublistView(f.readSync(4)).getUint32(0);
          case 'CHNL':
            channels = ByteData.sublistView(f.readSync(2)).getUint16(0);
          case 'CMPR':
            compressed = String.fromCharCodes(f.readSync(4)) != 'DSD ';
          case 'DSD ':
            dataOffset = body;
            dataBytes = size;
        }
        at = body + size + (size.isOdd ? 1 : 0);
      }
    }

    chunks(16, length); // after "FRM8", size and "DSD "
    if (compressed || rate == null || channels == null || channels == 0 || dataOffset == null) return null;
    if (rate! % 44100 != 0) return null;
    return DsdFile._(
      path: path,
      channels: channels!,
      bitRate: rate!,
      bytesPerChannel: dataBytes! ~/ channels!,
      dataOffset: dataOffset!,
      blockSize: 0,
      lsbFirst: false,
    );
  }
}

/// A DSD file as DoP ("DSD over PCM"): a 24-bit WAV whose samples each carry
/// 16 DSD bits under a marker byte (0x05 / 0xFA, alternating). Played
/// bit-perfect, a DAC that knows DoP sees the markers and plays the DSD
/// itself; nothing is converted.
class DopAudioSource extends StreamAudioSource {
  DopAudioSource(this.dsd, {super.tag});

  final DsdFile dsd;

  static const headerSize = 68;

  int get _frameBytes => dsd.channels * 3;
  int get length => headerSize + dsd.frames * _frameBytes;

  /// RIFF / WAVE_FORMAT_EXTENSIBLE header for 24-bit PCM at the DoP rate.
  Uint8List header() {
    final h = ByteData(headerSize);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    final data = dsd.frames * _frameBytes;
    tag(0, 'RIFF');
    h.setUint32(4, (length - 8).clamp(0, 0xFFFFFFFF), Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    h.setUint32(16, 40, Endian.little);
    h.setUint16(20, 0xFFFE, Endian.little); // WAVE_FORMAT_EXTENSIBLE
    h.setUint16(22, dsd.channels, Endian.little);
    h.setUint32(24, dsd.dopRate, Endian.little);
    h.setUint32(28, dsd.dopRate * _frameBytes, Endian.little);
    h.setUint16(32, _frameBytes, Endian.little);
    h.setUint16(34, 24, Endian.little);
    h.setUint16(36, 22, Endian.little);
    h.setUint16(38, 24, Endian.little); // valid bits
    h.setUint32(40, dsd.channels == 2 ? 3 : 0, Endian.little); // front left + right
    // KSDATAFORMAT_SUBTYPE_PCM
    const guid = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71];
    for (var i = 0; i < 16; i++) {
      h.setUint8(44 + i, guid[i]);
    }
    tag(60, 'data');
    h.setUint32(64, data.clamp(0, 0xFFFFFFFF), Endian.little);
    return h.buffer.asUint8List();
  }

  static final _reversed = Uint8List.fromList([
    for (var b = 0; b < 256; b++)
      [for (var i = 0; i < 8; i++) (b >> i) & 1].fold<int>(0, (acc, bit) => (acc << 1) | bit),
  ]);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = (end ?? length).clamp(from, length);
    return StreamAudioResponse(
      sourceLength: length,
      contentLength: to - from,
      offset: from,
      contentType: 'audio/wav',
      stream: bytes(from, to),
    );
  }

  /// Frames packed per read: one DSF block per channel (DSF blocks are 4096
  /// bytes, two per frame), or the same amount of DSDIFF.
  int get _framesPerChunk => dsd.blockSize > 0 ? dsd.blockSize ~/ 2 : 2048;

  /// Bytes [from, to) of the WAV.
  Stream<Uint8List> bytes(int from, int to) async* {
    if (from < headerSize) {
      yield Uint8List.sublistView(header(), from, to < headerSize ? to : headerSize);
      from = headerSize;
    }
    if (from >= to) return;
    final file = await File(dsd.path).open();
    try {
      var frame = (from - headerSize) ~/ _frameBytes;
      var skip = (from - headerSize) % _frameBytes;
      final lastFrame = (to - headerSize + _frameBytes - 1) ~/ _frameBytes; // exclusive
      var left = to - from;
      while (frame < lastFrame && left > 0) {
        final chunk = frame ~/ _framesPerChunk;
        final first = chunk * _framesPerChunk;
        final count = ((chunk + 1) * _framesPerChunk).clamp(0, dsd.frames) - first;
        final out = await _pack(file, first, count);
        final begin = (frame - first) * _frameBytes + skip;
        final end = (begin + left).clamp(0, out.length);
        yield Uint8List.sublistView(out, begin, end);
        left -= end - begin;
        frame = first + count;
        skip = 0;
      }
    } finally {
      await file.close();
    }
  }

  /// DoP frames [first, first + count) as little-endian 24-bit samples.
  Future<Uint8List> _pack(RandomAccessFile file, int first, int count) async {
    final ch = dsd.channels;
    final out = Uint8List(count * ch * 3);
    final byteFrom = first * 2; // per channel
    if (dsd.blockSize > 0) {
      // Chunks are block-aligned: one block per channel, [ch0 block][ch1 block]...
      final bs = dsd.blockSize;
      await file.setPosition(dsd.dataOffset + (byteFrom ~/ bs) * bs * ch);
      final src = await file.read(bs * ch);
      return _fill(out, src, first, count, (c, i) => c * bs + i, 1);
    }
    await file.setPosition(dsd.dataOffset + byteFrom * ch);
    final src = await file.read(count * 2 * ch);
    return _fill(out, src, first, count, (c, i) => i * ch + c, ch);
  }

  /// [at] gives the offset in [src] of channel c's i-th byte of the chunk;
  /// [step] is the distance to that channel's next byte.
  Uint8List _fill(Uint8List out, Uint8List src, int first, int count, int Function(int c, int i) at, int step) {
    final ch = dsd.channels;
    final rev = dsd.lsbFirst;
    var o = 0;
    for (var f = 0; f < count; f++) {
      final marker = (first + f).isEven ? 0x05 : 0xFA;
      for (var c = 0; c < ch; c++) {
        final i0 = at(c, f * 2), i1 = i0 + step;
        // Past the end of the file (a short last block): DSD silence.
        var b0 = i0 < src.length ? src[i0] : 0x69;
        var b1 = i1 < src.length ? src[i1] : 0x69;
        if (rev) {
          b0 = _reversed[b0];
          b1 = _reversed[b1];
        }
        // Oldest DSD byte in the middle, marker on top (little-endian: low byte first).
        out[o++] = b1;
        out[o++] = b0;
        out[o++] = marker;
      }
    }
    return out;
  }
}
