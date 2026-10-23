import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/metadata.dart';

/// Files someone made to hurt the app: the size fields in them lie.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('openmusic-hostile'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// "fLaC", a STREAMINFO block, then a PICTURE block whose MIME type claims [mimeLength] bytes.
  File flacWithPicture({required int mimeLength}) {
    final b = BytesBuilder()..add('fLaC'.codeUnits);
    // STREAMINFO (type 0, 34 bytes): 44.1 kHz, stereo, 16-bit, 441000 samples.
    b.add([0x00, 0x00, 0x00, 34]);
    b.add(Uint8List(10));
    b.add((ByteData(8)..setUint64(0, (44100 << 44) | (1 << 41) | (15 << 36) | 441000)).buffer.asUint8List());
    b.add(Uint8List(16));
    // PICTURE (type 6, last block), 64 bytes of body that start with the lying length.
    b.add([0x86, 0x00, 0x00, 64]);
    b.add(
      (ByteData(8)
            ..setUint32(0, 3) // front cover
            ..setUint32(4, mimeLength))
          .buffer
          .asUint8List(),
    );
    b.add(Uint8List(56));
    return File('${dir.path}/hostile.flac')..writeAsBytesSync(b.takeBytes());
  }

  test('a picture claiming a gigabyte is refused, without allocating it', () async {
    // Small enough to be allocated (bigger claims fail at once), so only a check catches it.
    final file = flacWithPicture(mimeLength: 1 << 30);
    final peak = ProcessInfo.maxRss;
    final clock = Stopwatch()..start();
    expect(() => readMetadata(file, getImage: true), throwsA(isA<MetadataParserException>()));
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(ProcessInfo.maxRss - peak, lessThan(100 << 20), reason: 'memory it should never have taken');
    // The app shows no cover for it and carries on.
    expect(await Metadata.artwork(Track.fromUri(Uri.file(file.path))), isNull);
  });

  test('the same file without the lie still reads', () {
    final file = flacWithPicture(mimeLength: 10);
    expect(() => readMetadata(file), returnsNormally);
  });
}
