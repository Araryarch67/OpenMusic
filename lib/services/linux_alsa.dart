import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A sound card output as the kernel lists it.
class AlsaOutput {
  const AlsaOutput({required this.card, required this.device, required this.cardId, required this.name});

  final int card;
  final int device;

  /// The card's short id (`Audio`, `PCH`…), stable across reboots unlike [card].
  final String cardId;
  final String name;

  /// mpv's name for the raw hardware device: no conversion, no mixing.
  String get mpvName => 'alsa/hw:CARD=$cardId,DEV=$device';
}

/// What the DAC is actually being fed, from `/proc/asound/.../hw_params`.
class HwParams {
  const HwParams({required this.format, required this.rate, required this.channels});

  /// ALSA format name: `S16_LE`, `S24_3LE`, `S32_LE`, `FLOAT_LE`…
  final String format;
  final int rate;
  final int channels;

  int? get bits => switch (format) {
    'S16_LE' || 'S16_BE' => 16,
    'S24_LE' || 'S24_BE' || 'S24_3LE' || 'S24_3BE' => 24,
    'S32_LE' || 'S32_BE' || 'FLOAT_LE' || 'FLOAT_BE' => 32,
    'FLOAT64_LE' || 'FLOAT64_BE' => 64,
    'U8' || 'S8' => 8,
    'DSD_U8' || 'DSD_U16_LE' || 'DSD_U32_LE' || 'DSD_U16_BE' || 'DSD_U32_BE' => 1,
    _ => null,
  };

  bool get isFloat => format.startsWith('FLOAT');

  @visibleForTesting
  static HwParams? parse(String text) {
    String? field(String key) => RegExp('^$key: (\\S+)', multiLine: true).firstMatch(text)?[1];
    final format = field('format');
    final rate = int.tryParse(field('rate') ?? '');
    final channels = int.tryParse(field('channels') ?? '');
    if (format == null || rate == null) return null;
    return HwParams(format: format, rate: rate, channels: channels ?? 0);
  }
}

/// Linux sound-card plumbing for bit-perfect playback: finding the hardware
/// behind an output, asking PipeWire to let go of it, and reading back what
/// the DAC receives.
abstract final class LinuxAlsa {
  static bool get supported => Platform.isLinux && Directory('/proc/asound').existsSync();

  /// Every playback device of every card (`/proc/asound/cardN/pcmDp`).
  static List<AlsaOutput> outputs() {
    if (!supported) return const [];
    final out = <AlsaOutput>[];
    final cards = File('/proc/asound/cards').readAsStringSync();
    for (final m in RegExp(r'^\s*(\d+) \[(\S+)\s*\]: [^\n]* - ([^\n]+)$', multiLine: true).allMatches(cards)) {
      final card = int.parse(m[1]!);
      final id = m[2]!;
      final cardName = m[3]!.trim();
      final dir = Directory('/proc/asound/card$card');
      if (!dir.existsSync()) continue;
      for (final pcm in dir.listSync().whereType<Directory>()) {
        final d = RegExp(r'pcm(\d+)p$').firstMatch(pcm.path);
        if (d == null) continue;
        final device = int.parse(d[1]!);
        var name = cardName;
        try {
          final info = File('${pcm.path}/info').readAsStringSync();
          final pcmName = RegExp(r'^name: (.+)$', multiLine: true).firstMatch(info)?[1]?.trim();
          if (pcmName != null && pcmName.isNotEmpty && !cardName.contains(pcmName)) name = '$cardName, $pcmName';
        } catch (_) {}
        out.add(AlsaOutput(card: card, device: device, cardId: id, name: name));
      }
    }
    out.sort((a, b) => a.card != b.card ? a.card.compareTo(b.card) : a.device.compareTo(b.device));
    return out;
  }

  static AlsaOutput? byMpvName(String name) => outputs().where((o) => o.mpvName == name).firstOrNull;

  /// The card + device behind a PipeWire output: [node] is a PipeWire node name
  /// (`alsa_output.usb-…`), or null for the system default.
  static Future<AlsaOutput?> behind(String? node) async {
    try {
      final r = await Process.run('wpctl', [
        'inspect',
        node == null ? '@DEFAULT_AUDIO_SINK@' : await _nodeId(node) ?? '',
      ]);
      if (r.exitCode != 0) return null;
      final props = r.stdout as String;
      String? prop(String key) => RegExp('$key = "([^"]*)"').firstMatch(props)?[1];
      final card = int.tryParse(prop(r'alsa\.card') ?? '');
      final device = int.tryParse(prop(r'alsa\.device') ?? '0') ?? 0;
      if (card == null) return null;
      return outputs().where((o) => o.card == card && o.device == device).firstOrNull;
    } catch (_) {
      return null; // no wpctl: not PipeWire
    }
  }

  static Future<String?> _nodeId(String nodeName) async {
    final r = await Process.run('pw-dump', ['Node']);
    if (r.exitCode != 0) return null;
    for (final o in (jsonDecode(r.stdout as String) as List).cast<Map<String, dynamic>>()) {
      final props = (o['info'] as Map?)?['props'] as Map?;
      if (props?['node.name'] == nodeName) return '${o['id']}';
    }
    return null;
  }

  /// What the card is playing right now, or null when it's closed.
  static HwParams? hwParams(AlsaOutput o) {
    try {
      final f = File('/proc/asound/card${o.card}/pcm${o.device}p/sub0/hw_params');
      return HwParams.parse(f.readAsStringSync());
    } catch (_) {
      return null;
    }
  }
}

/// Holds a sound card for OpenMusic alone.
///
/// PipeWire keeps every card open, so opening the raw device would fail with
/// "busy". Like JACK, ask it to step aside through the standard D-Bus device
/// reservation (`org.freedesktop.ReserveDevice1.AudioN`, via `pw-reserve`).
/// While held, other apps' sound moves to another output; [release] hands the
/// card back and restores the system's default output.
class CardReservation {
  CardReservation._(this.card, this._process, this._defaultSink);

  final int card;
  final Process _process;

  /// The default output before taking the card: PipeWire picks another one
  /// while the card is away and doesn't always switch back by itself.
  final String? _defaultSink;

  /// Null when it couldn't be had (no pw-reserve, or another program refused).
  static Future<CardReservation?> acquire(int card) async {
    final defaultSink = await _defaultSinkName();
    Process p;
    try {
      // `cat` waits on our stdin: when OpenMusic exits (even killed), the pipe
      // closes, cat returns and the reservation ends with it.
      p = await Process.start('sh', [
        '-c',
        'pw-reserve -n Audio$card -r -a OpenMusic -p 10 & r=\$!; trap "kill \$r 2>/dev/null" EXIT INT TERM; '
            'cat >/dev/null',
      ]);
    } catch (_) {
      return null;
    }
    final acquired = Completer<bool>();
    void onLine(String line) {
      if (line.contains('reserve acquired') && !acquired.isCompleted) acquired.complete(true);
      // "device AudioN is busy" comes first, before it asks PipeWire to let go: not a failure.
      if (line.contains('lost') && !acquired.isCompleted) acquired.complete(false);
    }

    final out = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
    final err = p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
    p.exitCode.then((_) {
      if (!acquired.isCompleted) acquired.complete(false);
    });
    final ok = await acquired.future.timeout(const Duration(seconds: 4), onTimeout: () => false);
    if (!ok) {
      p.kill();
      await out.cancel();
      await err.cancel();
      return null;
    }
    // Give PipeWire a moment to close the device after letting go of it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return CardReservation._(card, p, defaultSink);
  }

  Future<void> release() async {
    _process.kill();
    final wanted = _defaultSink;
    if (wanted == null) return;
    // PipeWire recreates the card's output (sometimes with a ".2" suffix) a moment later.
    final base = wanted.replaceFirst(RegExp(r'\.\d+$'), '');
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final now = await _defaultSinkName();
      if (now != null && now.replaceFirst(RegExp(r'\.\d+$'), '') == base) return;
      final id = await _sinkId(base);
      if (id != null) {
        await Process.run('wpctl', ['set-default', id]);
        return;
      }
    }
  }

  static Future<String?> _defaultSinkName() async {
    try {
      final r = await Process.run('wpctl', ['inspect', '@DEFAULT_AUDIO_SINK@']);
      return RegExp(r'node\.name = "([^"]+)"').firstMatch(r.stdout as String)?[1];
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _sinkId(String baseName) async {
    try {
      final r = await Process.run('pw-dump', ['Node']);
      for (final o in (jsonDecode(r.stdout as String) as List).cast<Map<String, dynamic>>()) {
        final props = (o['info'] as Map?)?['props'] as Map?;
        final name = props?['node.name'] as String?;
        if (props?['media.class'] == 'Audio/Sink' &&
            name != null &&
            name.replaceFirst(RegExp(r'\.\d+$'), '') == baseName) {
          return '${o['id']}';
        }
      }
    } catch (_) {}
    return null;
  }
}
