import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How loudness differences between songs are evened out (mpv `replaygain`).
enum VolumeLeveling {
  off('Off', 'no'),
  track('Per song', 'track'),
  album('Per album', 'album');

  const VolumeLeveling(this.label, this.mpv);
  final String label;
  final String mpv;
}

/// Output buffering: shorter reacts faster, longer survives a busy system.
enum BufferSize {
  low('Low latency', 0.05),
  balanced('Balanced', 0.2),
  stable('Extra stable', 1.0);

  const BufferSize(this.label, this.seconds);
  final String label;
  final double seconds;
}

/// One peaking filter of the equalizer.
class EqBand {
  const EqBand(this.frequency, this.gain, {this.q = 1.41});

  factory EqBand.fromJson(Map<String, dynamic> j) =>
      EqBand((j['f'] as num).toDouble(), (j['g'] as num).toDouble(), q: (j['q'] as num).toDouble());

  final double frequency;

  /// dB, -12..12.
  final double gain;

  /// Bandwidth; 1.41 is one octave, larger is narrower.
  final double q;

  EqBand copyWith({double? frequency, double? gain, double? q}) =>
      EqBand(frequency ?? this.frequency, gain ?? this.gain, q: q ?? this.q);

  Map<String, dynamic> toJson() => {'f': frequency, 'g': gain, 'q': q};
}

/// Ready-made equalizer curves (gains for the ten default bands).
const eqPresets = <String, List<double>>{
  'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Bass boost': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
  'Bass cut': [-6, -5, -3, -1, 0, 0, 0, 0, 0, 0],
  'Treble boost': [0, 0, 0, 0, 0, 1, 2, 4, 5, 6],
  'Vocal': [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1],
  'Rock': [4, 3, 2, 0, -1, -1, 1, 2, 3, 4],
  'Pop': [-1, 1, 3, 4, 3, 0, -1, -1, 0, 1],
  'Jazz': [3, 2, 1, 2, -1, -1, 0, 1, 2, 3],
  'Classical': [4, 3, 2, 1, -1, -1, 0, 2, 3, 4],
  'Electronic': [5, 4, 1, 0, -2, 1, 0, 1, 4, 5],
  'Loudness': [5, 3, 0, 0, -1, 0, -1, 0, 3, 4],
};

const defaultEqFrequencies = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

/// An output the user can pick (mpv `audio-device`).
class OutputDevice {
  const OutputDevice(this.name, this.description, {this.direct = false});

  /// mpv's id, e.g. `pipewire/alsa_output...`, `alsa/front:CARD=DAC,DEV=0`, `wasapi/{...}`.
  final String name;
  final String description;

  /// Bypasses the system mixer (Linux ALSA hardware device): nothing else can
  /// play meanwhile, and the DAC gets the file's own rate and bits.
  final bool direct;
}

/// What is actually happening to the sound right now, read back from mpv.
class SignalPath {
  const SignalPath({
    required this.codec,
    required this.container,
    required this.inFormat,
    required this.inRate,
    required this.inChannels,
    required this.outFormat,
    required this.outRate,
    required this.outChannels,
    required this.output,
    required this.device,
    required this.filters,
    required this.volume,
    required this.leveling,
    required this.bitrate,
    this.sourceBits,
  });

  final String codec;
  final String container;
  final String inFormat;
  final int inRate;
  final int inChannels;
  final String outFormat;
  final int outRate;
  final int outChannels;

  /// mpv audio output driver (pipewire, alsa, wasapi, coreaudio...).
  final String output;
  final String device;

  /// Processing stages between decoder and output, in order.
  final List<String> filters;
  final double volume;
  final bool leveling;
  final int? bitrate;

  /// Bit depth stored in the file (24 for a 24-bit FLAC that decodes to `s32`), when known.
  final int? sourceBits;

  static const _lossless = {
    'flac', 'alac', 'wavpack', 'ape', 'tta', 'truehd', 'mlp', 'shorten', 'tak', //
    'pcm_s16le', 'pcm_s16be', 'pcm_s24le', 'pcm_s24be', 'pcm_s32le', 'pcm_s32be', 'pcm_f32le', 'pcm_f32be',
    'pcm_f64le', 'pcm_f64be', 'pcm_u8', 'pcm_s8',
  };

  bool get isDsd => codec.startsWith('dsd_');
  bool get lossless => _lossless.contains(codec) || isDsd || codec.startsWith('pcm_');

  /// Bits per sample of a decoded format name like `s16`, `s32p`, `floatp`.
  static int? bitsOf(String format) => switch (format.replaceAll(RegExp(r'p$'), '')) {
    'u8' || 's8' => 8,
    's16' => 16,
    's24' => 24,
    's32' => 32,
    'float' => 32,
    'double' => 64,
    's64' => 64,
    _ => null,
  };

  static bool _isFloat(String f) => f.startsWith('float') || f.startsWith('double');

  /// Mixed by the OS (PipeWire / PulseAudio / shared WASAPI) rather than sent to the DAC as-is.
  bool get viaSystemMixer => switch (output) {
    'pipewire' || 'pulse' || 'jack' || 'openal' || 'sdl' || 'opensles' || 'audiotrack' || 'aaudio' => true,
    'alsa' => !RegExp(r'^alsa/(hw|plughw|front|iec958|hdmi|usbstream):').hasMatch(device) || device.contains('plughw'),
    _ => false,
  };

  /// The decoded samples reach the output untouched: same rate, channels and
  /// sample values (an integer format may be padded wider, which is lossless).
  bool get untouched {
    if (filters.isNotEmpty || leveling || (volume - 100).abs() > 0.01) return false;
    if (inRate != outRate || inChannels != outChannels) return false;
    if (inFormat == outFormat) return true;
    final a = bitsOf(inFormat), b = bitsOf(outFormat);
    if (a == null || b == null || _isFloat(inFormat) != _isFloat(outFormat)) return false;
    return b >= a;
  }

  bool get bitPerfect => untouched && !viaSystemMixer && !isDsd;

  /// e.g. "24-bit / 96 kHz". [stored] overrides the bit count for padded formats.
  static String describe(String format, int rate, {int? stored}) {
    final bits = _isFloat(format) ? bitsOf(format) : stored ?? bitsOf(format);
    final f = _isFloat(format) ? '${bits ?? 32}-bit float' : (bits == null ? format : '$bits-bit');
    return '$f / ${formatRate(rate)}';
  }

  static String formatRate(int rate) {
    final k = rate / 1000;
    return '${k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1)} kHz';
  }
}

/// Audio settings applied to libmpv (desktop) and read back as a [SignalPath].
///
/// Everything here goes through mpv properties on the player behind just_audio:
/// equalizer and crossfeed are lavfi filters, leveling is mpv's ReplayGain,
/// output/exclusive/rate/resampler are AO options. On platforms where
/// just_audio uses its own native backend (Android/iOS/macOS) [supported] is
/// false and the settings UI hides itself.
class AudioEngine extends ChangeNotifier {
  AudioEngine() {
    // Pitch control makes media_kit own the `af` property (scaletempo); the app needs it for EQ.
    JustAudioMediaKit.pitch = false;
    JustAudioMediaKit.onPlayerCreated = (p) => unawaited(_applyAll(p));
  }

  static bool get supported => Platform.isLinux || Platform.isWindows;

  /// Whether the OS output can be opened exclusively by mpv's own option
  /// (WASAPI / CoreAudio). On Linux a direct ALSA device does the same.
  static bool get hasExclusiveMode => Platform.isWindows || Platform.isMacOS;

  static const _key = 'audio.v1';

  bool gapless = true;
  VolumeLeveling leveling = VolumeLeveling.off;
  BufferSize buffer = BufferSize.balanced;

  bool eqEnabled = false;
  String eqPreset = 'Flat';
  List<EqBand> bands = [for (final f in defaultEqFrequencies) EqBand(f, 0)];

  /// Headphone crossfeed strength 0..1 (0 = off).
  double crossfeed = 0;

  String device = 'auto';
  bool exclusive = false;

  /// Null follows each song's own rate.
  int? outputRate;
  bool hqResampler = true;

  /// Everything off, volume fixed at 100%, exclusive output: nothing touches the samples.
  bool bitPerfect = false;

  List<OutputDevice> devices = const [OutputDevice('auto', 'System default')];

  Player? get _player => JustAudioMediaKit.activePlayer;

  NativePlayer? get _native => switch (_player?.platform) {
    final NativePlayer p => p,
    _ => null,
  };

  // ── Persistence ─────────────────────────────────────────────────────────

  Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      gapless = j['gapless'] as bool? ?? gapless;
      leveling = VolumeLeveling.values.asNameMap()[j['leveling']] ?? leveling;
      buffer = BufferSize.values.asNameMap()[j['buffer']] ?? buffer;
      eqEnabled = j['eqEnabled'] as bool? ?? eqEnabled;
      eqPreset = j['eqPreset'] as String? ?? eqPreset;
      final b = j['bands'] as List?;
      if (b != null && b.isNotEmpty) bands = [for (final x in b) EqBand.fromJson((x as Map).cast())];
      crossfeed = (j['crossfeed'] as num?)?.toDouble() ?? crossfeed;
      device = j['device'] as String? ?? device;
      exclusive = j['exclusive'] as bool? ?? exclusive;
      outputRate = j['outputRate'] as int?;
      hqResampler = j['hqResampler'] as bool? ?? hqResampler;
      bitPerfect = j['bitPerfect'] as bool? ?? bitPerfect;
    } catch (e) {
      debugPrint('Ignoring bad audio settings: $e');
    }
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _key,
    jsonEncode({
      'gapless': gapless,
      'leveling': leveling.name,
      'buffer': buffer.name,
      'eqEnabled': eqEnabled,
      'eqPreset': eqPreset,
      'bands': [for (final b in bands) b.toJson()],
      'crossfeed': crossfeed,
      'device': device,
      'exclusive': exclusive,
      'outputRate': outputRate,
      'hqResampler': hqResampler,
      'bitPerfect': bitPerfect,
    }),
  );

  /// Persists, notifies, and pushes the change to the running player.
  ///
  /// Coalesced: dragging an EQ slider fires dozens of changes a second, and
  /// each rebuilds mpv's filter chain.
  Future<void> _changed({bool reopenOutput = false}) {
    notifyListeners();
    _reopen |= reopenOutput;
    _pending?.cancel();
    final done = _done ??= Completer<void>();
    _pending = Timer(const Duration(milliseconds: 80), () async {
      final reopen = _reopen;
      _reopen = false;
      _done = null;
      try {
        await _save();
        final p = _native;
        if (p != null) {
          await _applyProps(p);
          if (reopen) await p.command(['ao-reload']);
        }
      } catch (e) {
        debugPrint('Applying audio settings failed: $e');
      } finally {
        done.complete();
      }
    });
    return done.future;
  }

  Timer? _pending;
  Completer<void>? _done;
  bool _reopen = false;

  // ── Setters used by the UI ──────────────────────────────────────────────

  Future<void> setGapless(bool v) => _set(() => gapless = v);
  Future<void> setLeveling(VolumeLeveling v) => _set(() => leveling = v);
  Future<void> setBuffer(BufferSize v) => _set(() => buffer = v, reopen: true);
  Future<void> setCrossfeed(double v) => _set(() => crossfeed = v);
  Future<void> setDevice(String v) => _set(() => device = v);
  Future<void> setExclusive(bool v) => _set(() => exclusive = v, reopen: true);
  Future<void> setOutputRate(int? v) => _set(() => outputRate = v, reopen: true);
  Future<void> setHqResampler(bool v) => _set(() => hqResampler = v);
  Future<void> setBitPerfect(bool v) => _set(() => bitPerfect = v, reopen: true);

  Future<void> setEqEnabled(bool v) => _set(() => eqEnabled = v);

  Future<void> setBand(int i, EqBand band) => _set(() {
    bands = [...bands]..[i] = band;
    eqPreset = 'Custom';
  });

  Future<void> applyPreset(String name) => _set(() {
    final gains = eqPresets[name];
    if (gains == null) return;
    eqPreset = name;
    eqEnabled = true;
    bands = [for (var i = 0; i < defaultEqFrequencies.length; i++) EqBand(defaultEqFrequencies[i], gains[i])];
  });

  Future<void> _set(void Function() change, {bool reopen = false}) {
    change();
    return _changed(reopenOutput: reopen);
  }

  // ── mpv ─────────────────────────────────────────────────────────────────

  /// Equalizer curve active right now (bit-perfect mode bypasses everything).
  bool get eqActive => eqEnabled && !bitPerfect && bands.any((b) => b.gain.abs() > 0.05);
  bool get crossfeedActive => crossfeed > 0 && !bitPerfect;
  VolumeLeveling get effectiveLeveling => bitPerfect ? VolumeLeveling.off : leveling;

  /// Lowered so boosted bands can't clip: the loudest band ends at 0 dB.
  double get preamp {
    if (!eqActive) return 0;
    final peak = bands.map((b) => b.gain).reduce((a, b) => a > b ? a : b);
    return peak > 0 ? -peak : 0;
  }

  /// The mpv `af` chain. Labels let the signal path name each stage.
  String get filterChain {
    String n(double v) => v.toStringAsFixed(2);
    return [
      if (eqActive) ...[
        if (preamp < 0) '@preamp:lavfi=[volume=volume=${n(preamp)}dB]',
        '@eq:lavfi=[${bands.where((b) => b.gain.abs() > 0.05).map((b) => 'equalizer=f=${n(b.frequency)}:t=q:w=${n(b.q)}:g=${n(b.gain)}').join(',')}]',
      ],
      if (crossfeedActive) '@crossfeed:lavfi=[crossfeed=strength=${n(0.1 + crossfeed * 0.6)}:range=0.5]',
    ].join(',');
  }

  Future<void> _applyAll(Player player) async {
    if (player.platform case final NativePlayer p) {
      await refreshDevices(p);
      await _applyProps(p);
    }
  }

  Future<void> _applyProps(NativePlayer p) async {
    final exclusiveOut = exclusive || bitPerfect;
    final props = <String, String>{
      'gapless-audio': gapless ? 'weak' : 'no',
      'prefetch-playlist': gapless ? 'yes' : 'no',
      'replaygain': effectiveLeveling.mpv,
      'replaygain-clip': 'no',
      'replaygain-fallback': '0',
      'audio-buffer': buffer.seconds.toString(),
      'af': filterChain,
      'audio-device': device,
      'audio-exclusive': hasExclusiveMode && exclusiveOut ? 'yes' : 'no',
      'audio-samplerate': bitPerfect ? '0' : '${outputRate ?? 0}',
      // Only used when the rate has to change; keeps the default otherwise.
      'audio-swresample-o': hqResampler && !bitPerfect ? await _hqResampler() : '',
      // Volume and leveling bypassed: mpv must not scale samples at all.
      if (bitPerfect) 'volume': '100',
    };
    for (final e in props.entries) {
      await p.setProperty(e.key, e.value);
    }
  }

  static String? _resamplerOptions;

  /// SoX's resampler where libswresample was built with it, otherwise
  /// libswresample's own filter at its highest quality settings.
  static Future<String> _hqResampler() async {
    if (_resamplerOptions != null) return _resamplerOptions!;
    var soxr = false;
    if (Platform.isLinux) {
      try {
        final r = await Process.run('ffmpeg', ['-hide_banner', '-buildconf']);
        soxr = (r.stdout as String).contains('--enable-libsoxr');
      } catch (_) {}
    }
    return _resamplerOptions = soxr
        ? 'resampler=soxr,precision=28'
        : 'filter_size=64,phase_shift=10,cutoff=0.97,linear_interp=1';
  }

  /// The resampler that is used whenever a rate change is needed.
  static String get resamplerName =>
      (_resamplerOptions ?? '').contains('soxr') ? 'SoX (VHQ)' : 'libswresample (high quality)';

  Future<void> refreshDevices([NativePlayer? player]) async {
    final p = player ?? _native;
    if (p == null) return;
    try {
      final raw = await p.getProperty('audio-device-list');
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      devices = _usable([for (final d in list) (d['name'] as String, d['description'] as String? ?? '')]);
      notifyListeners();
    } catch (e) {
      debugPrint('audio-device-list: $e');
    }
  }

  /// Hides mpv's plumbing entries (ALSA plugins, duplicate PulseAudio
  /// mirrors of PipeWire nodes...) and marks direct hardware outputs.
  static List<OutputDevice> _usable(List<(String, String)> all) {
    final hasPipewire = all.any((d) => d.$1.startsWith('pipewire/'));
    final out = <OutputDevice>[const OutputDevice('auto', 'System default')];
    for (final (name, desc) in all) {
      if (!name.contains('/')) continue; // "pipewire", "alsa", "jack": just "default of this API"
      final api = name.split('/').first;
      if (api == 'pulse' && hasPipewire) continue;
      if (api == 'alsa') {
        final hw = RegExp(r'^alsa/(front|iec958|hdmi):').hasMatch(name);
        if (!hw) continue;
        out.add(OutputDevice(name, desc.split('/').first, direct: true));
        continue;
      }
      out.add(OutputDevice(name, desc));
    }
    return out;
  }

  static final _bitsCache = <String, int?>{};

  /// Reads the stored bit depth from a FLAC / WAV / AIFF header. mpv only
  /// reports the decoder's sample format, which pads 24-bit into 32.
  static Future<int?> _sourceBits(String path) async {
    if (path.isEmpty || path.startsWith('http')) return null;
    try {
      final f = await File(path).open();
      try {
        return parseSourceBits(await f.read(64 * 1024));
      } finally {
        await f.close();
      }
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static int? parseSourceBits(Uint8List b) {
    String tag(int at) => at + 4 <= b.length ? String.fromCharCodes(b.sublist(at, at + 4)) : '';
    int le32(int at) => b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;
    int be32(int at) => b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];
    if (tag(0) == 'fLaC' && b.length > 22) {
      // STREAMINFO follows the 4-byte block header; bits-per-sample − 1 straddles bytes 12–13.
      return (((b[8 + 12] & 0x01) << 4) | (b[8 + 13] >> 4)) + 1;
    }
    if (tag(0) == 'RIFF' && tag(8) == 'WAVE') {
      for (var at = 12; at + 8 <= b.length;) {
        final size = le32(at + 4);
        if (tag(at) == 'fmt ' && at + 24 <= b.length) return b[at + 22] | b[at + 23] << 8;
        at += 8 + size + (size & 1);
      }
    }
    if (tag(0) == 'FORM' && (tag(8) == 'AIFF' || tag(8) == 'AIFC')) {
      for (var at = 12; at + 8 <= b.length;) {
        final size = be32(at + 4);
        if (tag(at) == 'COMM' && at + 16 <= b.length) return b[at + 14] << 8 | b[at + 15];
        at += 8 + size + (size & 1);
      }
    }
    return null;
  }

  /// One read of the live signal path, or null when nothing is playing.
  Future<SignalPath?> signalPath() async {
    final p = _native;
    if (p == null) return null;
    Future<String> g(String k) async {
      try {
        return await p.getProperty(k, waitForInitialization: false);
      } catch (_) {
        return '';
      }
    }

    final inRate = int.tryParse(await g('audio-params/samplerate')) ?? 0;
    if (inRate == 0) return null;
    final af = await g('af');
    final file = await g('path');
    return SignalPath(
      sourceBits: _bitsCache[file] ??= await _sourceBits(file),
      codec: await g('audio-codec-name'),
      container: await g('file-format'),
      inFormat: await g('audio-params/format'),
      inRate: inRate,
      inChannels: int.tryParse(await g('audio-params/channel-count')) ?? 0,
      outFormat: await g('audio-out-params/format'),
      outRate: int.tryParse(await g('audio-out-params/samplerate')) ?? 0,
      outChannels: int.tryParse(await g('audio-out-params/channel-count')) ?? 0,
      output: await g('current-ao'),
      device: await g('audio-device'),
      filters: [
        for (final m in RegExp(r'@(\w+):').allMatches(af))
          switch (m[1]) {
            'eq' => 'Equalizer',
            'preamp' => 'Equalizer headroom',
            'crossfeed' => 'Headphone crossfeed',
            final other => other!,
          },
      ],
      volume: double.tryParse(await g('volume')) ?? 100,
      leveling: effectiveLeveling != VolumeLeveling.off,
      bitrate: int.tryParse(await g('audio-bitrate')),
    );
  }
}
