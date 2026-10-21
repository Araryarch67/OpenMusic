import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The LADSPA bridge to Carla (linux/carla_bridge), built here and run in
/// FFmpeg, whose filter chain is mpv's. Needs g++, Carla and the LSP plugins
/// (LV2); skipped without them.
void main() {
  late Directory dir;
  late String bridge;
  const fixture = 'test/fixtures/half_gain.carxp';
  final ready =
      Platform.isLinux &&
      File('/usr/lib/carla/libcarla_native-plugin.so').existsSync() &&
      Directory('/usr/lib/lv2/lsp-plugins.lv2').existsSync();

  setUpAll(() async {
    if (!ready) return;
    dir = Directory.systemTemp.createTempSync('plugins');
    bridge = '${dir.path}/libopenmusic_carla.so';
    final r = await Process.run('g++', [
      '-shared', '-fPIC', '-std=c++17', '-O2', '-Wall', '-Werror', '-fvisibility=hidden', //
      'linux/carla_bridge/openmusic_carla.cc', '-ldl', '-o', bridge,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  });
  tearDownAll(() {
    if (ready) dir.deleteSync(recursive: true);
  });

  /// Mean level (dB) and an MD5 of 2 s of a 1 kHz tone through [filter].
  Future<({double mean, String md5})> run(String filter, {String? project}) async {
    final env = {'OPENMUSIC_PLUGINS': project ?? '${dir.path}/none.carxp'};
    final input = ['-hide_banner', '-f', 'lavfi', '-i', 'sine=f=1000:d=2,aformat=channel_layouts=stereo'];
    final level = await Process.run('ffmpeg', [
      ...input,
      '-af',
      '$filter,volumedetect',
      '-f',
      'null',
      '-',
    ], environment: env);
    final hash = await Process.run('ffmpeg', [...input, '-af', filter, '-f', 'md5', '-'], environment: env);
    final mean = RegExp(r'mean_volume: (-?[\d.]+) dB').firstMatch(level.stderr as String);
    expect(mean, isNotNull, reason: '${level.stderr}');
    return (mean: double.parse(mean![1]!), md5: (hash.stdout as String).trim());
  }

  String plugin() => 'ladspa=file=$bridge:plugin=openmusic_carla';

  test('runs the plugins of a Carla project in the filter chain', () async {
    if (!ready) return markTestSkipped('needs Carla and lsp-plugins (LV2)');
    final plain = await run('anull');
    final processed = await run(plugin(), project: fixture);
    expect(processed.mean - plain.mean, closeTo(-6.0, 0.2), reason: 'the project halves the level');
  });

  test('passes the audio through untouched without a project', () async {
    if (!ready) return markTestSkipped('needs Carla and lsp-plugins (LV2)');
    final plain = await run('anull');
    final through = await run(plugin());
    expect(through.md5, plain.md5);
  });
}
