// StreamAudioSource/Response are just_audio's documented way to feed custom
// byte streams (see youtube_audio_source.dart).
// ignore_for_file: experimental_member_use

import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// 1-bit audio that can be read by position: a DSF / DSDIFF file, or a song
/// on an SACD image.
abstract interface class DsdSource {
  int get channels;

  /// 1-bit samples per second per channel: 2822400 for DSD64.
  int get bitRate;

  /// Audio bytes per channel (8 samples each).
  int get bytesPerChannel;

  /// [count] bytes of every channel from [byteFrom], byte-interleaved
  /// (ch0, ch1, ..., ch0, ...), oldest sample in each byte's top bit.
  Future<Uint8List> interleaved(int byteFrom, int count);
}

/// Where the 1-bit audio sits in a DSF or DSDIFF file.
class DsdFile implements DsdSource {
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
  @override
  final int channels;

  @override
  final int bitRate;

  /// Padding left out.
  @override
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

  static final _reversed = Uint8List.fromList([
    for (var b = 0; b < 256; b++)
      [for (var i = 0; i < 8; i++) (b >> i) & 1].fold<int>(0, (acc, bit) => (acc << 1) | bit),
  ]);

  @override
  Future<Uint8List> interleaved(int byteFrom, int count) async {
    final ch = channels;
    final out = Uint8List(count * ch)..fillRange(0, count * ch, 0x69); // past the end: DSD silence
    count = (bytesPerChannel - byteFrom).clamp(0, count);
    if (count == 0) return out;
    final f = await File(path).open();
    try {
      if (blockSize == 0) {
        // DSDIFF: interleaved already.
        await f.setPosition(dataOffset + byteFrom * ch);
        final src = await f.read(count * ch);
        out.setRange(0, src.length, src);
        return out;
      }
      // DSF: blocks of [blockSize] bytes per channel, one channel after another.
      final bs = blockSize;
      final firstBlock = byteFrom ~/ bs, lastBlock = (byteFrom + count - 1) ~/ bs;
      await f.setPosition(dataOffset + firstBlock * bs * ch);
      final src = await f.read((lastBlock - firstBlock + 1) * bs * ch);
      final rev = lsbFirst;
      for (var i = 0; i < count; i++) {
        final pos = byteFrom + i;
        final base = (pos ~/ bs - firstBlock) * bs * ch + pos % bs;
        for (var c = 0; c < ch; c++) {
          final at = base + c * bs;
          if (at >= src.length) continue;
          out[i * ch + c] = rev ? _reversed[src[at]] : src[at];
        }
      }
      return out;
    } finally {
      await f.close();
    }
  }

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

  final DsdSource dsd;

  int get frames => dsd.bytesPerChannel ~/ 2;
  int get dopRate => dsd.bitRate ~/ 16;

  static const headerSize = 68;

  int get _frameBytes => dsd.channels * 3;
  int get length => headerSize + frames * _frameBytes;

  /// RIFF / WAVE_FORMAT_EXTENSIBLE header for 24-bit PCM at the DoP rate.
  Uint8List header() {
    final h = ByteData(headerSize);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    final data = frames * _frameBytes;
    tag(0, 'RIFF');
    h.setUint32(4, (length - 8).clamp(0, 0xFFFFFFFF), Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    h.setUint32(16, 40, Endian.little);
    h.setUint16(20, 0xFFFE, Endian.little); // WAVE_FORMAT_EXTENSIBLE
    h.setUint16(22, dsd.channels, Endian.little);
    h.setUint32(24, dopRate, Endian.little);
    h.setUint32(28, dopRate * _frameBytes, Endian.little);
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

  /// DoP frames packed per read (16 KB of DSD per channel).
  static const _framesPerChunk = 8192;

  /// Bytes [from, to) of the WAV.
  Stream<Uint8List> bytes(int from, int to) async* {
    if (from < headerSize) {
      yield Uint8List.sublistView(header(), from, to < headerSize ? to : headerSize);
      from = headerSize;
    }
    if (from >= to) return;
    var frame = (from - headerSize) ~/ _frameBytes;
    var skip = (from - headerSize) % _frameBytes;
    final lastFrame = (to - headerSize + _frameBytes - 1) ~/ _frameBytes; // exclusive
    var left = to - from;
    while (frame < lastFrame && left > 0) {
      final first = frame ~/ _framesPerChunk * _framesPerChunk;
      final count = (first + _framesPerChunk).clamp(0, frames) - first;
      final out = _pack(await dsd.interleaved(first * 2, count * 2), first, count);
      final begin = (frame - first) * _frameBytes + skip;
      final end = (begin + left).clamp(0, out.length);
      yield Uint8List.sublistView(out, begin, end);
      left -= end - begin;
      frame = first + count;
      skip = 0;
    }
  }

  /// DoP frames [first, first + count) as little-endian 24-bit samples, from
  /// the matching interleaved DSD bytes.
  Uint8List _pack(Uint8List src, int first, int count) {
    final ch = dsd.channels;
    final out = Uint8List(count * ch * 3);
    var o = 0;
    for (var f = 0; f < count; f++) {
      final marker = (first + f).isEven ? 0x05 : 0xFA;
      for (var c = 0; c < ch; c++) {
        // Oldest DSD byte in the middle, marker on top (little-endian: low byte first).
        out[o++] = src[(f * 2 + 1) * ch + c];
        out[o++] = src[f * 2 * ch + c];
        out[o++] = marker;
      }
    }
    return out;
  }
}
