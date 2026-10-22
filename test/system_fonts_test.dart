import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/services/system_fonts.dart';

/// A font file holding nothing but a `name` table with [names] (name id → text), as Windows writes them.
Uint8List _font(Map<int, String> names) {
  final strings = BytesBuilder();
  final records = BytesBuilder();
  for (final e in names.entries) {
    final utf16 = [
      for (final c in e.value.codeUnits) ...[c >> 8, c & 0xFF],
    ];
    records.add(
      (ByteData(12)
            ..setUint16(0, 3) // Windows
            ..setUint16(2, 1) // Unicode BMP
            ..setUint16(4, 0x409) // English (US)
            ..setUint16(6, e.key)
            ..setUint16(8, utf16.length)
            ..setUint16(10, strings.length))
          .buffer
          .asUint8List(),
    );
    strings.add(utf16);
  }
  final header = ByteData(6)
    ..setUint16(0, 0)
    ..setUint16(2, names.length)
    ..setUint16(4, 6 + names.length * 12);
  final name = [...header.buffer.asUint8List(), ...records.takeBytes(), ...strings.takeBytes()];
  final sfnt = ByteData(12 + 16)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, 1)
    ..setUint32(12, 0x6E616D65) // 'name'
    ..setUint32(20, 28)
    ..setUint32(24, name.length);
  return Uint8List.fromList([...sfnt.buffer.asUint8List(), ...name]);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('fonts'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('reads the family from the name table, the typographic family first', () {
    final plain = File('${dir.path}/a.ttf')..writeAsBytesSync(_font({1: 'Inter', 2: 'Regular'}));
    expect(SystemFonts.familyOf(plain.path), 'Inter');

    // A bold face's family (id 1) is "Inter SemiBold"; its typographic family (id 16) groups it with the rest.
    final bold = File('${dir.path}/b.ttf')..writeAsBytesSync(_font({1: 'Inter SemiBold', 16: 'Inter'}));
    expect(SystemFonts.familyOf(bold.path), 'Inter');
  });

  test('not a font: no family', () {
    final junk = File('${dir.path}/junk.ttf')..writeAsBytesSync(utf8.encode('not a font'));
    expect(SystemFonts.familyOf(junk.path), isNull);
  });
}
