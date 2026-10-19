import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/audio_engine.dart';
import 'package:openmusic/services/cue_sheet.dart';
import 'package:openmusic/services/linux_alsa.dart';
import 'package:openmusic/services/lyrics.dart';
import 'package:openmusic/services/metadata.dart';
import 'package:shared_preferences/shared_preferences.dart';

SignalPath _path({
  String inFormat = 's16',
  int inRate = 44100,
  String outFormat = 's16',
  int outRate = 44100,
  String output = 'alsa',
  String device = 'alsa/front:CARD=DAC,DEV=0',
  List<String> filters = const [],
  double volume = 100,
  bool leveling = false,
  String codec = 'flac',
}) => SignalPath(
  codec: codec,
  container: 'flac',
  inFormat: inFormat,
  inRate: inRate,
  inChannels: 2,
  outFormat: outFormat,
  outRate: outRate,
  outChannels: 2,
  output: output,
  device: device,
  filters: filters,
  volume: volume,
  leveling: leveling,
  bitrate: null,
);

void main() {
  group('LRC lyrics', () {
    test('parses timestamps, repeated stamps, offset and word timings', () {
      final l = Lyrics.parse('''
[ar:Someone]
[offset:+500]
[00:01.00]First
[00:05.50][00:20.25]Chorus <00:06.00>line
[00:10.123]
''', source: 'test');
      expect(l.synced, isTrue);
      expect(l.lines.map((x) => x.text), ['First', 'Chorus line', '', 'Chorus line']);
      expect(l.lines.first.time, const Duration(milliseconds: 500));
      expect(l.lines[2].time, const Duration(milliseconds: 9623));
      expect(l.lineAt(Duration.zero), -1);
      expect(l.lineAt(const Duration(seconds: 6)), 1);
      expect(l.lineAt(const Duration(minutes: 5)), 3);
    });

    test('text without timestamps is plain lyrics', () {
      final l = Lyrics.parse('just\nwords', source: 'test');
      expect(l.synced, isFalse);
      expect(l.plain, 'just\nwords');
      expect(Lyrics.parse('  ', source: 'x').isEmpty, isTrue);
    });
  });

  group('cue sheets', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('cue'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('splits a whole-album file into songs', () {
      File('${dir.path}/album.flac').writeAsBytesSync([0]);
      final cue = File('${dir.path}/album.cue')
        ..writeAsStringSync('''
REM DATE 1999
PERFORMER "The Band"
TITLE "Live Album"
FILE "album.wav" WAVE
  TRACK 01 AUDIO
    TITLE "Opening"
    INDEX 00 00:00:00
    INDEX 01 00:00:32
  TRACK 02 AUDIO
    TITLE "Second Song"
    PERFORMER "Guest"
    INDEX 01 03:10:45
''');
      final r = CueSheet.read(cue);
      expect(r.covers, {'${dir.path}/album.flac'}, reason: 'FILE names the .wav, the rip is FLAC');
      expect(r.tracks, hasLength(2));
      final a = r.tracks[0], b = r.tracks[1];
      expect(a.title, 'Opening');
      expect(a.artist, 'The Band');
      expect(a.album, 'Live Album');
      expect(a.start, const Duration(milliseconds: 427));
      expect(a.end, const Duration(minutes: 3, seconds: 10, milliseconds: 600));
      expect(b.artist, 'Guest');
      expect(b.end, isNull);
      expect(b.isCueTrack, isTrue);
      expect(a.id, isNot(b.id));
      // Survives a save / load round trip.
      final back = Track.fromJson(a.toJson());
      expect(back.start, a.start);
      expect(back.end, a.end);
    });
  });

  group('signal path', () {
    test('bit-perfect only when nothing touches the samples and the mixer is bypassed', () {
      expect(_path().bitPerfect, isTrue);
      expect(_path(outFormat: 's32').bitPerfect, isTrue, reason: 'padding 16 → 32 bit is lossless');
      expect(_path(inFormat: 's32', outFormat: 's16').bitPerfect, isFalse);
      expect(_path(outRate: 48000).bitPerfect, isFalse);
      expect(_path(filters: ['Equalizer']).bitPerfect, isFalse);
      expect(_path(volume: 80).bitPerfect, isFalse);
      expect(_path(leveling: true).bitPerfect, isFalse);
      expect(_path(outFormat: 'float').bitPerfect, isFalse);
      final mixer = _path(output: 'pipewire', device: 'auto');
      expect(mixer.untouched, isTrue);
      expect(mixer.bitPerfect, isFalse);
      expect(_path(device: 'alsa/plughw:CARD=DAC').viaSystemMixer, isTrue);
      expect(_path(output: 'wasapi', device: 'wasapi/{x}').bitPerfect, isTrue);
    });

    test('reads the stored bit depth from file headers', () async {
      final dir = Directory.systemTemp.createTempSync('bits');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final (name, args, bits) in [
        ('a.flac', ['-sample_fmt', 's32'], 24),
        ('b.flac', ['-sample_fmt', 's16'], 16),
        ('c.wav', ['-c:a', 'pcm_s24le'], 24),
        ('d.aiff', ['-c:a', 'pcm_s16be'], 16),
        ('e.wv', ['-c:a', 'wavpack', '-sample_fmt', 's16p'], 16),
        ('f.m4a', ['-c:a', 'alac', '-sample_fmt', 's32p'], 24),
      ]) {
        final r = await Process.run('ffmpeg', [
          '-loglevel', 'error', '-f', 'lavfi', '-i', 'anullsrc=r=96000', '-t', '0.2', ...args, '${dir.path}/$name', //
        ]);
        if (r.exitCode != 0) return markTestSkipped('ffmpeg not available');
        final head = File('${dir.path}/$name').readAsBytesSync();
        expect(AudioEngine.parseSourceBits(head), bits, reason: name);
      }
      expect(SignalPath.describe('s32', 96000, stored: 24), '24-bit / 96 kHz');
      // Monkey's Audio 3.99: "MAC ", version 3990, descriptor 52 bytes, header with 24 bits at +16.
      final ape = Uint8List(128)
        ..setAll(0, 'MAC '.codeUnits)
        ..buffer.asByteData().setUint16(4, 3990, Endian.little)
        ..buffer.asByteData().setUint32(8, 52, Endian.little)
        ..buffer.asByteData().setUint16(52 + 16, 24, Endian.little);
      expect(AudioEngine.parseSourceBits(ape), 24);
    });

    test('reads what the DAC receives and judges it', () {
      final hw = HwParams.parse(
        'access: RW_INTERLEAVED\nformat: S24_3LE\nsubformat: STD\nchannels: 2\nrate: 96000 (96000/1)\n',
      )!;
      expect(hw.format, 'S24_3LE');
      expect(hw.bits, 24);
      expect(hw.rate, 96000);
      expect(HwParams.parse('closed'), isNull);
      SignalPath at(
        HwParams dac, {
        int? bits = 24,
        String output = 'alsa',
        String device = 'alsa/hw:CARD=Audio,DEV=0',
      }) => SignalPath(
        codec: 'flac',
        container: 'flac',
        inFormat: 's32',
        inRate: 96000,
        inChannels: 2, //
        outFormat: 's32',
        outRate: 96000,
        outChannels: 2,
        output: output,
        device: device,
        filters: const [],
        volume: 100,
        leveling: false,
        bitrate: null,
        sourceBits: bits,
        dac: dac,
      );
      expect(at(hw).bitPerfect, isTrue);
      expect(at(hw, bits: 32).bitPerfect, isFalse, reason: '32-bit file into a 24-bit DAC loses bits');
      const mixed = HwParams(format: 'S24_3LE', rate: 48000, channels: 2);
      final viaPipewire = at(mixed, output: 'pipewire', device: 'auto');
      expect(viaPipewire.mixerResamples, isTrue);
      expect(viaPipewire.bitPerfect, isFalse);
    });

    test('ASIO (mpv\'s own output): straight to the driver, resampling shows', () {
      SignalPath via({int outRate = 96000, String outFormat = 's32p'}) => SignalPath(
        codec: 'flac',
        container: 'flac',
        inFormat: 's32',
        inRate: 96000,
        inChannels: 2,
        outFormat: outFormat,
        outRate: outRate,
        outChannels: 2,
        output: 'asio',
        device: 'asio/Focusrite USB ASIO',
        filters: const [],
        volume: 100,
        leveling: false,
        bitrate: null,
        sourceBits: 24,
      );
      expect(via().viaSystemMixer, isFalse);
      expect(via().bitPerfect, isTrue, reason: 's32 into the driver\'s own Int32 buffers');
      expect(via(outRate: 48000).bitPerfect, isFalse, reason: 'the driver can\'t run at 96 kHz, mpv resampled');
      expect(via(outFormat: 's16p').bitPerfect, isFalse, reason: 'a 16-bit driver drops bits');
    });

    test('describes formats', () {
      expect(SignalPath.describe('s32', 96000), '32-bit / 96 kHz');
      expect(SignalPath.describe('floatp', 44100), '32-bit float / 44.1 kHz');
      expect(_path(codec: 'dsd_lsbf_planar').isDsd, isTrue);
    });
  });

  group('audio engine', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('equalizer builds an mpv filter chain with headroom', () async {
      final a = AudioEngine();
      expect(a.filterChain, isEmpty);
      await a.applyPreset('Bass boost');
      expect(a.eqActive, isTrue);
      expect(a.preamp, -6);
      expect(a.filterChain, startsWith('@preamp:lavfi=[volume=volume=-6.00dB],@eq:lavfi=[equalizer=f=31.00'));
      expect(a.filterChain, isNot(contains('f=1000.00')), reason: 'flat bands are left out');
      await a.setCrossfeed(0.5);
      expect(a.filterChain, contains('@crossfeed:lavfi=[crossfeed=strength=0.40'));
      await a.setBitPerfect(true);
      expect(a.filterChain, isEmpty);
      expect(a.effectiveLeveling, VolumeLeveling.off);
    });

    test('the filter chain really changes the sound (measured through mpv)', () async {
      final dir = Directory.systemTemp.createTempSync('dsp');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sine = '${dir.path}/sine.wav';
      final ok = await Process.run('ffmpeg', [
        '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=f=1000:d=2:r=48000', '-ac', '2', sine, //
      ]);
      if (ok.exitCode != 0) return markTestSkipped('ffmpeg not available');
      // 48 equal taps at 48 kHz: a moving average whose first null is exactly 1 kHz.
      final ir = '${dir.path}/boxcar.wav';
      await Process.run('ffmpeg', [
        '-loglevel', 'error', '-f', 'lavfi', '-i', "aevalsrc='if(lt(n,48),1/48,0)':s=48000:d=0.01", '-ac', '2', ir, //
      ]);

      Future<double> peakDb(String chain) async {
        final out = '${dir.path}/out.wav';
        final r = await Process.run('mpv', [
          '--no-config', '--ao=pcm', '--ao-pcm-file=$out', '--audio-format=s16', //
          if (chain.isNotEmpty) '--af=$chain', sine,
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final bytes = File(out).readAsBytesSync();
        final pcm = ByteData.sublistView(bytes, 44);
        var peak = 0;
        // Skip the first half second (filter start-up), measure the steady tone.
        for (var i = 48000 * 2 * 2; i + 1 < pcm.lengthInBytes; i += 2) {
          final v = pcm.getInt16(i, Endian.little).abs();
          if (v > peak) peak = v;
        }
        return 20 * math.log(peak / 32768) / math.ln10;
      }

      final dry = await peakDb('');
      final a = AudioEngine()..debugVolume = 0.25;
      final quieter = await peakDb(a.filterChain);
      printOnFailure('dry $dry dB, 25% volume $quieter dB');
      expect(quieter - dry, closeTo(-12.04, 0.2), reason: '25% volume is -12 dB');

      final b = AudioEngine()
        ..impulsePath = ir
        ..convolution = true;
      expect(b.filterChain, contains('afir'));
      final corrected = await peakDb(b.filterChain);
      // ignore: avoid_print
      print(
        'measured: dry ${dry.toStringAsFixed(2)} dB, volume 25% ${(quieter - dry).toStringAsFixed(2)} dB, room correction ${(corrected - dry).toStringAsFixed(1)} dB',
      );
      expect(corrected - dry, lessThan(-30), reason: 'the 1 kHz tone sits in the impulse response\'s null');

      // Positive control: a single unit impulse must leave the tone as it is.
      final dirac = '${dir.path}/dirac.wav';
      await Process.run('ffmpeg', [
        '-loglevel', 'error', '-f', 'lavfi', '-i', "aevalsrc='if(eq(n,0),1,0)':s=48000:d=0.01", '-ac', '2', dirac, //
      ]);
      final c = AudioEngine()
        ..impulsePath = dirac
        ..convolution = true;
      final passed = await peakDb(c.filterChain);
      // ignore: avoid_print
      print('dirac: ${(passed - dry).toStringAsFixed(2)} dB');
      expect((passed - dry).abs(), lessThan(1), reason: 'a unit impulse changes nothing');

      b.bitPerfect = true;
      expect(b.filterChain, isEmpty, reason: 'bit-perfect bypasses room correction');
    });

    test('settings persist', () async {
      final a = AudioEngine();
      await a.applyPreset('Rock');
      await a.setLeveling(VolumeLeveling.album);
      await a.setOutputRate(96000);
      final b = AudioEngine();
      await b.load();
      expect(b.eqPreset, 'Rock');
      expect(b.bands[0].gain, 4);
      expect(b.leveling, VolumeLeveling.album);
      expect(b.outputRate, 96000);
    });
  });

  group('tag editor', () {
    late Directory dir;
    setUpAll(Metadata.probeTagTools);
    setUp(() => dir = Directory.systemTemp.createTempSync('tags'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<String?> make(String name) async {
      final path = '${dir.path}/$name';
      final r = await Process.run('ffmpeg', [
        '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=d=1', //
        '-metadata', 'title=Old', '-metadata', 'REPLAYGAIN_TRACK_GAIN=-7.50 dB', '-metadata', 'MOOD=calm',
        path,
      ]);
      return r.exitCode == 0 ? path : null;
    }

    Future<Map<String, String>> probe(String path) async {
      final r = await Process.run('ffprobe', [
        '-v', 'error', '-show_entries', 'format_tags:stream_tags', '-of', 'json', path, //
      ]);
      final j = jsonDecode(r.stdout as String) as Map;
      final all = <dynamic, dynamic>{
        ...(j['format'] as Map)['tags'] as Map? ?? {},
        for (final st in j['streams'] as List) ...(st as Map)['tags'] as Map? ?? {},
      };
      return {for (final e in all.entries) (e.key as String).toLowerCase(): e.value as String};
    }

    test('MP4 is not offered: its tags could not be rewritten losslessly', () {
      expect(Metadata.canEditTags(Track.fromUri(Uri.file('/x/song.m4a'))), isFalse);
    });

    for (final ext in ['flac', 'mp3', 'ogg']) {
      test('edits $ext and keeps the tags it does not show', () async {
        final path = await make('song.$ext');
        if (path == null) return markTestSkipped('ffmpeg not available');
        final track = Track.fromUri(Uri.file(path));
        expect(Metadata.canEditTags(track), isTrue);
        final tags = await Metadata.readTags(track);
        expect(tags.title, 'Old');
        tags
          ..title = 'New title'
          ..artist = 'New artist'
          ..album = 'Album'
          ..discNumber = 2
          ..trackNumber = 7;
        final updated = await Metadata.writeTags(track, tags);
        expect(updated.title, 'New title');
        expect(updated.artist, 'New artist');
        expect(updated.trackNumber, 7);
        expect(updated.discNumber, 2);
        final after = await probe(path);
        expect(after['replaygain_track_gain'], '-7.50 dB', reason: 'ReplayGain survived');
        expect(after['mood'], 'calm', reason: 'custom tag survived');
        expect(dir.listSync().map((e) => e.path.split('/').last), ['song.$ext'], reason: 'no temp file left');
      });
    }
  });
}
