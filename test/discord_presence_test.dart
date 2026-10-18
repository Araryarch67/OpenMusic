import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/discord_presence.dart';

/// Minimal stand-in for Discord's IPC server.
class FakeDiscord {
  FakeDiscord._(this.server, this.path);

  final ServerSocket server;
  final String path;
  final frames = <(int, Map<String, dynamic>)>[];
  final _received = StreamController<void>.broadcast();

  static Future<FakeDiscord> start() async {
    final dir = Directory.systemTemp.createTempSync('fake-discord');
    final path = '${dir.path}/discord-ipc-0';
    final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    final fake = FakeDiscord._(server, path);
    server.listen((client) {
      var buf = <int>[];
      client.listen((data) {
        buf = [...buf, ...data];
        while (buf.length >= 8) {
          final h = ByteData.sublistView(Uint8List.fromList(buf.sublist(0, 8)));
          final op = h.getInt32(0, Endian.little), len = h.getInt32(4, Endian.little);
          if (buf.length < 8 + len) break;
          final json = jsonDecode(utf8.decode(buf.sublist(8, 8 + len))) as Map<String, dynamic>;
          buf = buf.sublist(8 + len);
          fake.frames.add((op, json));
          fake._received.add(null);
          if (op == 0) {
            final reply = utf8.encode(jsonEncode({'cmd': 'DISPATCH', 'evt': 'READY', 'data': {'v': 1}}));
            final header = ByteData(8)
              ..setInt32(0, 1, Endian.little)
              ..setInt32(4, reply.length, Endian.little);
            client.add([...header.buffer.asUint8List(), ...reply]);
          }
        }
      });
    });
    return fake;
  }

  Future<void> waitForFrames(int n) async {
    while (frames.length < n) {
      await _received.stream.first.timeout(const Duration(seconds: 10));
    }
  }
}

void main() {
  test('handshake, listening activity with progress and button, then clear on pause', () async {
    final fake = await FakeDiscord.start();
    final presence = DiscordPresence('1561368591297941655', socketPaths: () => [fake.path]);
    final track = Track.youtube(videoId: 'kJQP7kiw5Fk', title: 'Despacito', artist: 'Luis Fonsi');

    presence.update(
      track: track,
      playing: true,
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 4, seconds: 41),
    );
    await fake.waitForFrames(2);

    final (hsOp, handshake) = fake.frames[0];
    expect(hsOp, 0);
    expect(handshake, {'v': 1, 'client_id': '1561368591297941655'});

    final (op, cmd) = fake.frames[1];
    expect(op, 1);
    expect(cmd['cmd'], 'SET_ACTIVITY');
    final activity = (cmd['args'] as Map)['activity'] as Map;
    expect(activity['type'], 2);
    expect(activity['details'], 'Despacito');
    expect(activity['state'], 'Luis Fonsi');
    final ts = activity['timestamps'] as Map;
    expect((ts['end'] as int) - (ts['start'] as int), const Duration(minutes: 4, seconds: 41).inMilliseconds);
    expect((activity['assets'] as Map)['large_image'], startsWith('https://i.ytimg.com/vi/kJQP7kiw5Fk/'));
    expect(((activity['buttons'] as List).single as Map)['url'], 'https://music.youtube.com/watch?v=kJQP7kiw5Fk');

    // Pausing clears the presence (sent after the rate-limit window).
    presence.update(track: track, playing: false, position: const Duration(seconds: 31));
    await fake.waitForFrames(3);
    expect((fake.frames[2].$2['args'] as Map)['activity'], isNull);

    presence.dispose();
    await fake.server.close();
  });
}
