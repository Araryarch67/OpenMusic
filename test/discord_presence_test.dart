import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/discord_presence.dart';

/// Discord's answer to a message: READY for the handshake, a reply for every command.
List<int> _reply(int op, Map<String, dynamic> json) {
  final body = utf8.encode(
    jsonEncode(
      op == 0
          ? {'cmd': 'DISPATCH', 'evt': 'READY', 'data': {'v': 1}}
          : {'cmd': json['cmd'], 'evt': null, 'nonce': json['nonce'], 'data': {}},
    ),
  );
  final header = ByteData(8)
    ..setInt32(0, 1, Endian.little)
    ..setInt32(4, body.length, Endian.little);
  return [...header.buffer.asUint8List(), ...body];
}

/// Minimal stand-in for Discord's IPC server: a Unix socket, or on Windows a
/// named pipe served by a small PowerShell script.
class FakeDiscord {
  FakeDiscord._(this.path, this._close);

  final String path;
  final Future<void> Function() _close;
  final frames = <(int, Map<String, dynamic>)>[];
  final _received = StreamController<void>.broadcast();

  void _frame(int op, Map<String, dynamic> json) {
    frames.add((op, json));
    _received.add(null);
  }

  static Future<FakeDiscord> start() => Platform.isWindows ? _pipe() : _socket();

  static Future<FakeDiscord> _socket() async {
    final dir = Directory.systemTemp.createTempSync('fake-discord');
    final path = '${dir.path}/discord-ipc-0';
    final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    final fake = FakeDiscord._(path, server.close);
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
          fake._frame(op, json);
          client.add(_reply(op, json));
        }
      });
    });
    return fake;
  }

  /// Answers like Discord and prints each frame it gets as `FRAME <op> <json>`.
  static const _pipeServer = r"""
$s = New-Object System.IO.Pipes.NamedPipeServerStream('PIPE_NAME', [System.IO.Pipes.PipeDirection]::InOut)
[Console]::Out.WriteLine('LISTENING'); [Console]::Out.Flush()
$s.WaitForConnection()
function ReadN($n) {
  $buf = New-Object byte[] $n; $got = 0
  while ($got -lt $n) { $r = $s.Read($buf, $got, $n - $got); if ($r -eq 0) { exit }; $got += $r }
  return ,$buf
}
while ($true) {
  $h = ReadN 8
  $body = ReadN ([BitConverter]::ToInt32($h, 4))
  [Console]::Out.WriteLine('FRAME ' + [BitConverter]::ToInt32($h, 0) + ' ' + [Text.Encoding]::UTF8.GetString($body))
  [Console]::Out.Flush()
  $op = [BitConverter]::ToInt32($h, 0)
  $json = if ($op -eq 0) { '{"cmd":"DISPATCH","evt":"READY","data":{"v":1}}' } else { '{"cmd":"SET_ACTIVITY","evt":null,"data":{}}' }
  $body = [Text.Encoding]::UTF8.GetBytes($json)
  $reply = [BitConverter]::GetBytes([int]1) + [BitConverter]::GetBytes([int]$body.Length) + $body
  $s.Write($reply, 0, $reply.Length); $s.Flush()
}
""";

  static Future<FakeDiscord> _pipe() async {
    final name = 'openmusic-test-discord-$pid';
    final proc = await Process.start('powershell', ['-NoProfile', '-Command', _pipeServer.replaceFirst('PIPE_NAME', name)]);
    final listening = Completer<void>();
    late final FakeDiscord fake;
    fake = FakeDiscord._(r'\\?\pipe\' + name, () async {
      proc.kill();
      await proc.exitCode;
    });
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line == 'LISTENING') listening.complete();
      final m = RegExp(r'^FRAME (\d+) (.*)$').firstMatch(line);
      if (m == null) return;
      fake._frame(int.parse(m[1]!), jsonDecode(m[2]!) as Map<String, dynamic>);
    });
    await listening.future.timeout(const Duration(seconds: 20));
    return fake;
  }

  Future<void> waitForFrames(int n) async {
    while (frames.length < n) {
      await _received.stream.first.timeout(const Duration(seconds: 10));
    }
  }

  Future<void> close() => _close();
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
    await fake.close();
  });
}
