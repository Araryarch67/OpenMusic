import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AnimatedSwitcher child swap', (tester) async {
    final handle = tester.ensureSemantics();
    var state = 0;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: state == 0
                    ? const SizedBox(key: ValueKey('a'), width: 50, height: 50)
                    : Container(key: const ValueKey('b'), width: 50, height: 50, color: Colors.red),
              ),
            );
          },
        ),
      ),
    );
    setOuter(() => state = 1);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    handle.dispose();
  });

  testWidgets('Artwork placeholder to image', (tester) async {
    final handle = tester.ensureSemantics();
    var showImage = false;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: showImage
                    ? Image(key: const ValueKey('img'), image: MemoryImage(_transparentImage))
                    : const Icon(Icons.music_note, key: ValueKey('ph')),
              ),
            );
          },
        ),
      ),
    );
    setOuter(() => showImage = true);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    handle.dispose();
  });
}

final _transparentImage = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);
