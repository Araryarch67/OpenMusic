import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'linux_alsa.dart';

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

/// Both sides played as one sound: in both ears, or in one when the other side
/// of the headphones doesn't work.
enum MonoAudio {
  off('Off (stereo)'),
  both('Both ears'),
  left('Left ear only'),
  right('Right ear only');

  const MonoAudio(this.label);
  final String label;
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

  /// Bypasses the system mixer (a Linux ALSA hardware device, a Windows ASIO
  /// driver): nothing else can play meanwhile, and the DAC gets the file's own rate and bits.
  final bool direct;
}

/// A DSD file being sent as DoP.
class DsdPlayback {
  const DsdPlayback(this.bitRate);

  /// 1-bit samples per second: 2822400 for DSD64.
  final int bitRate;
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
    this.exclusive = false,
    required this.filters,
    required this.volume,
    this.volumeAtOutput = false,
    required this.leveling,
    required this.bitrate,
    this.sourceBits,
    this.dac,
    this.dacName,
    this.dopBitRate,
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

  /// The output is held exclusively (WASAPI / CoreAudio exclusive mode), past the OS mixer.
  final bool exclusive;

  /// Processing stages between decoder and output, in order.
  final List<String> filters;

  /// Gain in percent (100 is untouched).
  final double volume;

  /// [volume] is mpv's own, applied to the output's samples (float through
  /// the system mixer) rather than by OpenMusic's 64-bit float filter.
  final bool volumeAtOutput;

  /// The arithmetic [volume] is applied in.
  String get volumePrecision => !volumeAtOutput || outFormat.startsWith('double')
      ? '64-bit float'
      : outFormat.startsWith('float')
      ? '32-bit float'
      : 'fixed point';

  final bool leveling;
  final int? bitrate;

  /// Bit depth stored in the file (24 for a 24-bit FLAC that decodes to `s32`), when known.
  final int? sourceBits;

  /// Set while a DSD file goes out as DoP: its 1-bit rate (2822400 for DSD64).
  /// mpv then sees 24-bit PCM, and only bit-perfect output keeps it DSD.
  final int? dopBitRate;

  bool get isDop => dopBitRate != null;

  /// What the sound card is really being fed (Linux reads it from the kernel).
  final HwParams? dac;
  final String? dacName;

  /// The card gets this stream's samples as they are: same rate and channels,
  /// integer, at least as many bits as the file has.
  bool get dacMatches {
    final d = dac;
    if (d == null) return true;
    final need = sourceBits ?? bitsOf(inFormat) ?? 99;
    return d.rate == inRate && d.channels == inChannels && !d.isFloat && (d.bits ?? 0) >= need;
  }

  /// The system mixer runs the card at another rate than the song's.
  bool get mixerResamples => viaSystemMixer && dac != null && dac!.rate != inRate;

  static const _lossless = {
    'flac', 'alac', 'wavpack', 'ape', 'tta', 'truehd', 'mlp', 'shorten', 'tak', //
    'pcm_s16le', 'pcm_s16be', 'pcm_s24le', 'pcm_s24be', 'pcm_s32le', 'pcm_s32be', 'pcm_f32le', 'pcm_f32be',
    'pcm_f64le', 'pcm_f64be', 'pcm_u8', 'pcm_s8',
  };

  /// DSD, or DST (an SACD's losslessly compressed DSD).
  bool get isDsd => codec.startsWith('dsd_') || codec == 'dst';
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
    'pipewire' ||
    'pulse' ||
    'jack' ||
    'openal' ||
    'sdl' ||
    'opensles' ||
    'audiotrack' ||
    'aaudio' ||
    'audiounit' => true,
    // Shared mode goes through Windows' / macOS's mixer (its volume, effects and rate).
    'wasapi' || 'coreaudio' => !exclusive,
    // mpv hands an exclusive Core Audio output to this driver (hog mode, the DAC's own format).
    'coreaudio_exclusive' => false,
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
    if (a == null || b == null) return false;
    // The system mixer gets float (for mpv's volume, see [volumeAtOutput]; shared WASAPI takes
    // nothing else). It holds every sample exactly when its mantissa (24 bits, 53 in 64-bit
    // float) is as wide as the file's.
    if ((viaSystemMixer || volumeAtOutput) && !_isFloat(inFormat) && _isFloat(outFormat)) {
      return (b == 64 ? 53 : 24) >= (sourceBits ?? a);
    }
    if (_isFloat(inFormat) != _isFloat(outFormat)) return false;
    return b >= a;
  }

  bool get bitPerfect => untouched && !viaSystemMixer && !isDsd && dacMatches;

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

/// Audio settings applied to libmpv and read back as a [SignalPath].
///
/// Everything here goes through mpv properties on the player behind just_audio:
/// equalizer, crossfeed, room correction and Virtual speakers are lavfi filters,
/// Mono audio mpv's own channel conversion, leveling mpv's ReplayGain, and
/// output/exclusive/rate/resampler are AO options. Every platform's libmpv has
/// the FFmpeg filters these need: Linux's system one, and OpenMusic's own
/// builds elsewhere (tool/build_libmpv_*.sh). What an OS can't offer (a device
/// choice on Android) has its `has…` flag.
class AudioEngine extends ChangeNotifier {
  AudioEngine() {
    // Pitch control makes media_kit own the `af` property (scaletempo); the app needs it for EQ.
    JustAudioMediaKit.pitch = false;
    // mpv's read-ahead (media_kit: 32 MiB ahead and 32 MiB behind, per open
    // file). 8 MiB is a whole YouTube song, or 15 s of 24/192 FLAC from disk.
    JustAudioMediaKit.bufferSize = 8 << 20;
    // mpv's `title`: the app's name in Windows' volume mixer (media_kit's default is "JustAudioMediaKit").
    // PulseAudio / PipeWire take `audio-client-name` instead (see [_applyProps]).
    JustAudioMediaKit.title = 'OpenMusic';
    JustAudioMediaKit.volumeOverride = _volumeTo;
    JustAudioMediaKit.onPlayerCreated = (p) => unawaited(_applyAll(p));
  }

  static bool get supported =>
      Platform.isLinux || Platform.isWindows || Platform.isAndroid || Platform.isMacOS || Platform.isIOS;

  /// Android and iOS offer no device choice or exclusive output: the system mixer plays everything.
  static bool get hasOutputChoice => !Platform.isAndroid && !Platform.isIOS;

  /// Whether the OS output can be opened exclusively by mpv's own option
  /// (WASAPI / CoreAudio). On Linux a direct ALSA device does the same.
  static bool get hasExclusiveMode =>
      defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS;

  static const _key = 'audio.v1';

  bool gapless = true;
  VolumeLeveling leveling = VolumeLeveling.off;
  BufferSize buffer = BufferSize.balanced;

  bool eqEnabled = false;
  String eqPreset = 'Flat';
  List<EqBand> bands = [for (final f in defaultEqFrequencies) EqBand(f, 0)];

  /// Headphone crossfeed strength 0..1 (0 = off).
  double crossfeed = 0;

  /// Headphones play the song as two loudspeakers in front of the listener
  /// would sound: each ear hears both speakers, through the head-related
  /// impulse responses in [hrirAsset] (FFmpeg's `headphone` filter).
  bool virtualSpeakers = false;

  /// MIT's KEMAR dummy head, speakers at ±30°, 48 kHz (made by `tool/make_hrir.sh`).
  static const hrirAsset = 'assets/audio/hrir_kemar_48k.wav';

  /// The rate [hrirAsset] was made at.
  static const _hrirRate = 48000;

  /// [hrirAsset] as a file FFmpeg can open (assets aren't files on Android, iOS or macOS).
  String? hrirPath;

  MonoAudio mono = MonoAudio.off;

  /// Room correction: an impulse response (WAV/FLAC, e.g. from REW) convolved
  /// with everything played. Kept as a copy in the app's folder, see [setImpulse].
  String? impulsePath;
  String? impulseName;
  bool convolution = false;

  String device = 'auto';

  /// Windows: WASAPI exclusive mode, past Windows' mixer. Other apps go silent
  /// meanwhile and Windows' volume mixer can't reach the player, so only this
  /// switch asks for it (Bit-perfect mode alone keeps the device shared).
  bool exclusive = false;

  /// mpv's `audio-exclusive`.
  bool get exclusiveOutput => hasExclusiveMode && exclusive;

  /// The sound reaches the DAC without the OS mixer in between: Exclusive mode
  /// or an ASIO driver on Windows, a direct card (Bit-perfect mode's) on Linux.
  bool get bypassesMixer =>
      hasExclusiveMode ? exclusive || device.startsWith('asio/') : bitPerfect || device.startsWith('alsa/');

  /// Null follows each song's own rate.
  int? outputRate;
  bool hqResampler = true;

  /// Bit-perfect mode leaves the rate alone, except through Windows' shared
  /// mixer: mpv still converts to the mixer's rate there, so with this resampler.
  bool get hqResamplerActive => hqResampler && !(bitPerfect && bypassesMixer);

  /// Everything off: nothing in the player touches the samples. On Linux the
  /// output goes straight to the card; on Windows that takes [exclusive] too. The
  /// player's volume still works (the DAC may have none): untouched at 100%, 64-bit float below.
  bool bitPerfect = false;

  /// Audio plugins (VST2, LV2, CLAP, LADSPA...) set up in Carla's window and
  /// run in the filter chain through the bundled LADSPA bridge.
  bool plugins = false;

  /// The bridge in the app bundle (Linux): `lib/libopenmusic_carla.so`.
  static String? get pluginBridge {
    if (!Platform.isLinux) return null;
    final path = '${File(Platform.resolvedExecutable).parent.path}/lib/libopenmusic_carla.so';
    return File(path).existsSync() ? path : null;
  }

  static const _carlaDirs = [
    '/usr/lib/carla',
    '/usr/lib64/carla',
    '/usr/local/lib/carla',
    '/usr/lib/x86_64-linux-gnu/carla',
  ];

  /// Whether Carla is installed (the bridge loads it when a song starts).
  static bool get carlaInstalled => _carlaDirs.any((d) => File('$d/libcarla_native-plugin.so').existsSync());

  /// Plugins can be offered: Linux, the bridge in the bundle and Carla installed.
  static bool get hasPlugins => pluginBridge != null && carlaInstalled;

  /// The Carla project the bridge loads (it reads the same place).
  static String get pluginsProject {
    final env = Platform.environment;
    final config = (env['XDG_CONFIG_HOME'] ?? '').isNotEmpty ? env['XDG_CONFIG_HOME']! : '${env['HOME']}/.config';
    return '$config/openmusic/plugins.carxp';
  }

  bool get pluginsActive => plugins && !bitPerfect && hasPlugins && File(pluginsProject).existsSync();

  Future<void> setPlugins(bool v) => _set(() => plugins = v);

  StreamSubscription<FileSystemEvent>? _projectWatch;

  /// Opens Carla on the plugins project (made empty the first time). Saving
  /// there applies the plugins: a new filter instance loads the project.
  Future<void> editPlugins() async {
    final project = File(pluginsProject);
    if (!project.existsSync()) {
      await project.parent.create(recursive: true);
      await project.writeAsString(
        "<?xml version='1.0' encoding='UTF-8'?>\n<!DOCTYPE CARLA-PROJECT>\n<CARLA-PROJECT VERSION='2.5'>\n</CARLA-PROJECT>\n",
      );
    }
    _projectWatch ??= project.parent.watch().where((e) => e.path == project.path).listen((_) {
      if (pluginsActive) _changed();
    });
    await Process.start('carla', [project.path], mode: ProcessStartMode.detached);
    if (!plugins) await setPlugins(true);
  }

  /// DSD files go to the DAC as DSD, packed as DoP, instead of being
  /// converted to PCM. Needs [bitPerfect] (any change to the samples destroys
  /// DoP) and a DAC that understands DoP; others play it as faint hiss.
  bool nativeDsd = false;

  /// Whether DSD files are sent as DoP right now (a mixer in between would destroy it).
  bool get dopActive => nativeDsd && bitPerfect && bypassesMixer && hasOutputChoice;

  DsdPlayback? _dop;

  /// The DSD file playing as DoP, if one is (set by the player). Volume is
  /// held at 100% meanwhile: scaling the samples would destroy the DSD.
  DsdPlayback? get dopPlaying => _dop;

  set dopPlaying(DsdPlayback? v) {
    if (v?.bitRate == _dop?.bitRate) {
      _dop = v;
      return;
    }
    final volumeWasOn = _volumeActive;
    _dop = v;
    notifyListeners();
    if (_native case final p?) {
      _setChain(p).then((_) {
        // The output would otherwise stay in the volume filter's float format.
        if (v != null && volumeWasOn) return p.command(['ao-reload']);
      }).ignore();
    }
  }

  List<OutputDevice> devices = const [OutputDevice('auto', 'System default')];

  /// Why the chosen output couldn't be used as asked (shown under Output device).
  String? deviceError;

  /// Linux: the sound card held for direct, bit-perfect output.
  CardReservation? _reservation;
  String? _heldTarget;

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
      virtualSpeakers = j['virtualSpeakers'] as bool? ?? virtualSpeakers;
      mono = MonoAudio.values.asNameMap()[j['mono']] ?? mono;
      device = j['device'] as String? ?? device;
      exclusive = j['exclusive'] as bool? ?? exclusive;
      outputRate = j['outputRate'] as int?;
      hqResampler = j['hqResampler'] as bool? ?? hqResampler;
      bitPerfect = j['bitPerfect'] as bool? ?? bitPerfect;
      nativeDsd = j['nativeDsd'] as bool? ?? nativeDsd;
      plugins = j['plugins'] as bool? ?? plugins;
      impulsePath = j['impulsePath'] as String?;
      impulseName = j['impulseName'] as String?;
      convolution = (j['convolution'] as bool? ?? false) && impulsePath != null && File(impulsePath!).existsSync();
      if (!hasOutputChoice) {
        device = 'auto';
        bitPerfect = false;
        exclusive = false;
      }
    } catch (e) {
      debugPrint('Ignoring bad audio settings: $e');
    }
    if (virtualSpeakers) await _installHrir();
  }

  /// Copies [hrirAsset] next to the app's other files, for [hrirPath].
  Future<void> _installHrir() async {
    if (hrirPath != null) return;
    try {
      final data = await rootBundle.load(hrirAsset);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final file = File(p.join((await getApplicationSupportDirectory()).path, p.basename(hrirAsset)));
      if (!file.existsSync() || !listEquals(await file.readAsBytes(), bytes)) {
        await file.parent.create(recursive: true);
        final part = File('${file.path}.part');
        await part.writeAsBytes(bytes, flush: true);
        await part.rename(file.path);
      }
      hrirPath = file.path;
    } catch (e) {
      debugPrint('Virtual speakers: $e');
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
      'virtualSpeakers': virtualSpeakers,
      'mono': mono.name,
      'device': device,
      'exclusive': exclusive,
      'outputRate': outputRate,
      'hqResampler': hqResampler,
      'bitPerfect': bitPerfect,
      'nativeDsd': nativeDsd,
      'plugins': plugins,
      'impulsePath': impulsePath,
      'impulseName': impulseName,
      'convolution': convolution,
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
          final volumeMoved = await _applyProps(p);
          if (reopen || volumeMoved) await p.command(['ao-reload']);
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
  Future<void> setMono(MonoAudio v) => _set(() => mono = v);
  Future<void> setDevice(String v) => _set(() => device = v);

  Future<void> setVirtualSpeakers(bool v) async {
    if (v) await _installHrir();
    return _set(() => virtualSpeakers = v);
  }

  Future<void> setExclusive(bool v) => _set(() => exclusive = v, reopen: true);
  Future<void> setOutputRate(int? v) => _set(() => outputRate = v, reopen: true);
  Future<void> setHqResampler(bool v) => _set(() => hqResampler = v);
  Future<void> setBitPerfect(bool v) => _set(() => bitPerfect = v, reopen: true);
  Future<void> setNativeDsd(bool v) => _set(() => nativeDsd = v, reopen: true);

  Future<void> setEqEnabled(bool v) => _set(() => eqEnabled = v);

  Future<void> setConvolution(bool v) => _set(() => convolution = v && impulsePath != null);

  /// Uses [file] as the room-correction impulse response. It's copied under
  /// a plain name: the path goes inside an FFmpeg filter graph, where commas,
  /// colons and brackets in a user's file name would need escaping.
  Future<void> setImpulse(File file, {required String name, required Directory into}) async {
    await into.create(recursive: true);
    // The extension too: a name like "room.wav],..." would have written filters of its own into the graph.
    final base = file.path.split(RegExp(r'[/\\]')).last;
    final given = base.contains('.') ? base.split('.').last.toLowerCase() : '';
    final ext = RegExp(r'^[a-z0-9]{1,5}$').hasMatch(given) ? given : 'wav';
    final copy = File('${into.path}${Platform.pathSeparator}impulse-${DateTime.now().millisecondsSinceEpoch}.$ext');
    await file.copy(copy.path);
    final old = impulsePath;
    await _set(() {
      impulsePath = copy.path;
      impulseName = name;
      convolution = true;
    });
    if (old != null && old != copy.path) File(old).delete().ignore();
  }

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

  /// The player's volume (a gain, 0-1): mpv's own volume through the system
  /// mixer, the 64-bit float filter in [filterChain] otherwise (see [_volumeAtOutput]).
  double _volume = 1;

  /// The device mpv was last told to open: [_outputDevice] may stand in for [device].
  String? _openedDevice;

  /// Through the system mixer (outside bit-perfect mode) mpv's own volume is
  /// used. mpv applies it as the sound leaves its output buffer, so a slider
  /// drag is heard at once rather than a buffer later, and it holds from song
  /// to song. [filterChain] makes that output float, so it is the same float
  /// multiply as the filter (64-bit where the mixer takes it, as PipeWire does).
  ///
  /// Elsewhere (a DAC direct, exclusive or ASIO output) the output is integer,
  /// where mpv's volume has only 256 steps, so the 64-bit filter applies it
  /// ahead of the buffer. Android keeps the filter too: its outputs aren't
  /// known to take float.
  bool get _volumeAtOutput {
    if (!hasOutputChoice || bitPerfect) return false;
    final d = _openedDevice ?? device;
    return hasExclusiveMode ? !exclusive && !d.startsWith('asio/') : !d.startsWith('alsa/');
  }

  /// Whether [_volumeAtOutput] held when the settings last reached mpv.
  bool? _volumeAtOutputApplied;

  /// mpv's `volume` for [_volume] (mpv's gain is the cube of volume / 100).
  String get _mpvVolume => _volumeAtOutput ? (100 * math.pow(_volume, 1 / 3)).toStringAsFixed(6) : '100';

  bool get _volumeActive => _volume < 0.99999 && _dop == null && !_volumeAtOutput;

  @visibleForTesting
  set debugVolume(double v) => _volume = v;

  /// The player's volume (a gain, 0-1), as the app's volume control set it.
  double get volume => _volume;

  /// Sets [volume] for the song playing and every one after it, in any mpv
  /// player to come. Only the app sets it: just_audio's own volume is ignored.
  Future<void> setVolume(double gain) {
    _volume = gain.clamp(0, 1);
    return switch (_player) {
      final p? => _volumeTo(p),
      null => Future.value(), // no player yet: [_applyProps] gives the next one [volume]
    };
  }

  Future<void>? _volumeApplying;
  bool _volumeDirty = false;

  /// Applies [volume] to [player]. Also what just_audio's setVolume does, so
  /// the level it replays to each new player (or changes itself) is never used.
  Future<void> _volumeTo(Player player) {
    if (_dop != null) return Future.value(); // held at 100% while DoP plays; applied when it ends
    if (player.platform case final NativePlayer p) {
      if (_volumeAtOutput) return p.setProperty('volume', _mpvVolume);
      // A slider drag sends dozens of levels a second. Sent concurrently, an
      // `af-command` could reach mpv before the chain holding the volume filter
      // was set (and be lost), so they go one at a time and the last one wins.
      _volumeDirty = true;
      return _volumeApplying ??= _applyVolume(p);
    }
    return Future.value();
  }

  /// When `af` was last set: mpv builds the new filter graph only once audio flows through it.
  DateTime _chainSetAt = DateTime(0);

  /// The `af` mpv holds. A level sent to the running filter isn't in it, and
  /// mpv builds each song's filters afresh from it (see [_applyAll]).
  String? _chainSent;

  Future<void> _setChain(NativePlayer p) async {
    final chain = filterChain;
    await p.setProperty('af', chain);
    _chainSent = chain;
    _chainSetAt = DateTime.now();
  }

  Future<void> _applyVolume(NativePlayer p) async {
    try {
      while (_volumeDirty && _dop == null) {
        _volumeDirty = false;
        // What mpv runs now, not what was last asked: settings changes rebuild the chain too.
        final inChain = (await p.getProperty('af')).contains('@volume:');
        // mpv refuses a filter command while no audio flows (paused, loading, a graph not
        // built yet), and media_kit only logs that. Rebuilding the chain is silent then.
        final flowing = await p.getProperty('core-idle') == 'no';
        if (inChain && _volumeActive && flowing) {
          // A graph set a moment ago may not be running yet.
          final wait = _chainSetAt.add(const Duration(milliseconds: 150)).difference(DateTime.now());
          if (wait > Duration.zero) await Future<void>.delayed(wait);
          // Just a new level: tell the running filter instead of rebuilding the chain (no click).
          // No target argument: the bundled Windows libmpv's af-command takes only three (and
          // ignores four), and the `@volume` graph holds nothing but the volume filter.
          await p.command(['af-command', 'volume', 'volume', _volume.toStringAsFixed(6)]);
        } else if (inChain || _volumeActive) {
          await _setChain(p);
          // Back at 100%: the output still runs in the volume filter's 64-bit float
          // until it reopens, so bit-perfect mode would stay not bit-perfect.
          if (inChain && !_volumeActive && bitPerfect) await p.command(['ao-reload']);
        }
      }
    } catch (e) {
      debugPrint('Applying volume failed: $e');
    } finally {
      _volumeApplying = null;
    }
    // Once a drag settles, `af` gets the level the running filter has, so filters mpv
    // rebuilds mid-song (an output reopening by itself) don't go back to the old one.
    // Only the volume filter's level differs, and mpv swaps it without a click.
    _chainSync?.cancel();
    _chainSync = Timer(const Duration(milliseconds: 500), () {
      if (_volumeApplying == null && _chainSent != filterChain && identical(_native, p)) _setChain(p).ignore();
    });
  }

  Timer? _chainSync;

  /// Equalizer curve active right now (bit-perfect mode bypasses everything).
  bool get eqActive => eqEnabled && !bitPerfect && bands.any((b) => b.gain.abs() > 0.05);
  bool get monoActive => mono != MonoAudio.off && !bitPerfect;

  /// Off under [monoActive]: summed to one channel, the two ears' responses
  /// would only colour the sound.
  bool get virtualSpeakersActive => virtualSpeakers && hrirPath != null && !bitPerfect && !monoActive;

  /// Virtual speakers already feed each ear the other side, the way crossfeed does.
  bool get crossfeedActive => crossfeed > 0 && !bitPerfect && !monoActive && !virtualSpeakersActive;
  bool get convolutionActive => convolution && impulsePath != null && !bitPerfect;
  VolumeLeveling get effectiveLeveling => bitPerfect ? VolumeLeveling.off : leveling;

  /// Lowered so boosted bands can't clip: the loudest band ends at 0 dB.
  double get preamp {
    if (!eqActive) return 0;
    final peak = bands.map((b) => b.gain).reduce((a, b) => a > b ? a : b);
    return peak > 0 ? -peak : 0;
  }

  /// A file name as an FFmpeg filter option inside a filter graph: escaped once
  /// for the option (`:`), once more for the graph (`[`, `,`, `;`). Windows'
  /// drive letters, an apostrophe in a user name, brackets in a folder name...
  @visibleForTesting
  static String graphPath(String path) {
    String escape(String s, String special) => s.split('').map((c) => special.contains(c) ? '\\$c' : c).join();
    return escape(escape(path.replaceAll('\\', '/'), "\\':"), "\\'[],;");
  }

  /// An mpv `lavfi` filter whose graph mpv takes as it is, by length (`%n%`):
  /// a bracket in a file name can't end it early.
  static String _lavfi(String label, String graph) => '@$label:lavfi=graph=%${utf8.encode(graph).length}%$graph';

  /// Mono through mpv's own channel conversion (FFmpeg's `pan` is missing from
  /// some libmpv builds): mixed to one channel, then to both sides, each at
  /// half of left plus right, so nothing can clip. For one ear, the copy on
  /// the other side is relabelled as LFE, which mixing back to stereo drops.
  String get _monoChain => [
    '@${switch (mono) {
      MonoAudio.left => 'monoleft',
      MonoAudio.right => 'monoright',
      _ => 'mono',
    }}:format=format=double:channels=mono',
    'format=channels=stereo',
    if (mono == MonoAudio.left || mono == MonoAudio.right) ...[
      'format=channels=3.1',
      mono == MonoAudio.left ? 'format=out-channels=fl-lfe-fc-fr' : 'format=out-channels=lfe-fr-fc-fl',
      'format=channels=stereo',
    ],
  ].join(',');

  /// Virtual speakers at the output's rate, 48 kHz when it follows the song:
  /// `headphone` would otherwise move the whole song to [hrirAsset]'s rate,
  /// with FFmpeg's default resampler. Here mpv converts the song (with the
  /// high-quality resampler), and only the IR is resampled when the rates differ.
  String get _virtualSpeakersChain {
    final rate = outputRate ?? _hrirRate;
    // `headphone` lowers by 3 dB per input channel; a resampled IR has rate / 48k more gain.
    final gain = 6.0206 + 20 * math.log(_hrirRate / rate) / math.ln10;
    final ir = 'amovie=filename=${graphPath(hrirPath!)}${rate == _hrirRate ? '' : ',aresample=$rate'}';
    return [
      'format=srate=$rate:channels=stereo',
      _lavfi('hrtf', '$ir[ir];[in][ir]headphone=map=FL|FR:hrir=multich:type=freq:gain=${gain.toStringAsFixed(4)}[out]'),
    ].join(',');
  }

  /// The mpv `af` chain. Labels let the signal path name each stage.
  String get filterChain {
    String n(double v) => v.toStringAsFixed(2);
    return [
      // First: room correction applies to the signal as a whole.
      if (convolutionActive) _lavfi('convolution', 'amovie=filename=${graphPath(impulsePath!)}[ir];[in][ir]afir[out]'),
      if (eqActive) ...[
        if (preamp < 0) '@preamp:lavfi=[volume=volume=${n(preamp)}dB]',
        '@eq:lavfi=[${bands.where((b) => b.gain.abs() > 0.05).map((b) => 'equalizer=f=${n(b.frequency)}:t=q:w=${n(b.q)}:g=${n(b.gain)}').join(',')}]',
      ],
      if (pluginsActive) '@plugins:lavfi=[ladspa=file=${pluginBridge!.replaceAll(':', '\\:')}:plugin=openmusic_carla]',
      if (virtualSpeakersActive) _virtualSpeakersChain,
      if (crossfeedActive) '@crossfeed:lavfi=[crossfeed=strength=${n(0.1 + crossfeed * 0.6)}:range=0.5]',
      // After the stereo stages: what's left is one channel.
      if (monoActive) _monoChain,
      // Last, so nothing after it can clip what it lowered.
      if (_volumeActive) '@volume:lavfi=[volume=volume=${_volume.toStringAsFixed(6)}:precision=double]',
      // Float output for mpv's volume (lossless: the system mixer works in float anyway).
      if (_volumeAtOutput) '@output:format=format=double',
    ].join(',');
  }

  Future<void> _applyAll(Player player) async {
    if (player.platform case final NativePlayer p) {
      // A level sent to the running filter is lost when the next song's filters
      // are built from `af`, and the song would start at the old level. Before a
      // song loads (no filters run then), `af` gets the current one. That also puts
      // the chain in place if the first song loads before [_applyProps] is done.
      _chainSent = null; // a new mpv: its `af` is empty
      // just_audio loads the first song without waiting for this setup, and mpv takes the
      // output's settings (device, exclusive mode, rate, buffer) when the song opens it:
      // the song waits here until they are in.
      final applied = Completer<void>();
      p.onLoadHooks.add(() async {
        await applied.future;
        if (_chainSent != filterChain) await _setChain(p);
      });
      try {
        await refreshDevices(p);
        await _applyProps(p);
      } finally {
        applied.complete();
      }
    }
  }

  /// Whether the volume moved between mpv's volume and the filter
  /// ([_volumeAtOutput]): the output must then reopen, in float or back in the song's format.
  Future<bool> _applyProps(NativePlayer p) async {
    _openedDevice = await _outputDevice();
    final props = <String, String>{
      // media_kit turns on mpv's disk cache, which fails ("Failed to create file
      // cache") without a writable cache dir. Audio needs no more than the RAM cache.
      'cache-on-disk': 'no',
      // Seeking back a few seconds stays instant; further back re-reads the file.
      'demuxer-max-bytes': '${JustAudioMediaKit.bufferSize}',
      'demuxer-max-back-bytes': '${2 << 20}',
      'gapless-audio': gapless ? 'weak' : 'no',
      'prefetch-playlist': gapless ? 'yes' : 'no',
      'replaygain': effectiveLeveling.mpv,
      'replaygain-clip': 'no',
      'replaygain-fallback': '0',
      'audio-buffer': buffer.seconds.toString(),
      'af': filterChain,
      'audio-device': _openedDevice!,
      // The app's name in the Linux mixers (PulseAudio / PipeWire); mpv's default is "mpv".
      'audio-client-name': 'OpenMusic',
      // macOS, shared: in bit-perfect mode the DAC follows each song's rate, so Core Audio's mixer
      // doesn't resample (Exclusive mode takes the device's own format anyway).
      if (Platform.isMacOS) 'coreaudio-change-physical-format': bitPerfect ? 'yes' : 'no',
      'audio-exclusive': exclusiveOutput ? 'yes' : 'no',
      'audio-samplerate': bitPerfect ? '0' : '${outputRate ?? 0}',
      // Only used when the rate has to change; keeps the default otherwise.
      'audio-swresample-o': hqResamplerActive ? await _hqResampler() : '',
      // 100 where the filter applies the volume: mpv must not scale samples too.
      'volume': _mpvVolume,
    };
    for (final e in props.entries) {
      await p.setProperty(e.key, e.value);
    }
    _chainSent = props['af'];
    _chainSetAt = DateTime.now();
    final moved = _volumeAtOutputApplied != null && _volumeAtOutputApplied != _volumeAtOutput;
    _volumeAtOutputApplied = _volumeAtOutput;
    return moved;
  }

  /// The mpv device to open. On Linux, bit-perfect mode goes straight to the
  /// sound card behind the chosen output (the system mixer would resample),
  /// and a direct card is first taken over from PipeWire.
  Future<String> _outputDevice() async {
    // The chosen output is unplugged (e.g. a USB DAC): forcing it gives no sound
    // at all, so play through the system default until it's back. The choice is
    // kept; [refreshDevices] runs for every new player, so it returns by itself.
    final listed = devices.length > 1; // the list failed to load otherwise
    if (device != 'auto' && listed && !devices.any((d) => d.name == device)) {
      _releaseCard();
      _setDeviceError('The chosen output isn\'t connected, so it plays through the system default for now.');
      return 'auto';
    }
    if (!LinuxAlsa.supported) return device;
    var target = device;
    if (bitPerfect && LinuxAlsa.byMpvName(device) == null) {
      // Already holding the card: keep it. (While it's held, PipeWire's default
      // output is some other card, so asking again would pick the wrong one.)
      final held = _reservation == null ? null : _heldTarget;
      final hw = held == null ? await _behind(device) : null;
      target = held ?? hw?.mpvName ?? device;
    }
    final card = LinuxAlsa.byMpvName(target);
    if (card == null) {
      _releaseCard();
      _setDeviceError(null);
      return target;
    }
    if (_reservation?.card == card.card) return target;
    _releaseCard();
    final got = await CardReservation.acquire(card.card);
    if (_disposed) {
      got?.release(); // closed while waiting: don't leave the card held
      return target;
    }
    _reservation = got;
    _heldTarget = got == null ? null : target;
    if (_reservation == null) {
      _setDeviceError('${card.name} is busy, so it plays through the system mixer for now.');
      return device == target ? 'auto' : device;
    }
    _setDeviceError(null);
    return target;
  }

  void _setDeviceError(String? e) {
    if (deviceError == e) return;
    deviceError = e;
    notifyListeners();
  }

  void _releaseCard() {
    _reservation?.release().ignore();
    _reservation = null;
    _behindCache.clear(); // the card's output comes back under a new id
  }

  final _behindCache = <String, (DateTime, AlsaOutput?)>{};

  /// The card behind a mixer output (`auto`, `pipewire/<node>`), cached briefly:
  /// asking PipeWire spawns a process, and this runs on every settings change.
  Future<AlsaOutput?> _behind(String mpvDevice) async {
    final hit = _behindCache[mpvDevice];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(seconds: 10)) return hit.$2;
    final node = switch (mpvDevice) {
      'auto' || 'pipewire' || 'pulse' => null,
      final d when d.startsWith('pipewire/') => d.substring('pipewire/'.length),
      final d when d.startsWith('pulse/') => d.substring('pulse/'.length),
      _ => null,
    };
    final out = await LinuxAlsa.behind(node);
    _behindCache[mpvDevice] = (DateTime.now(), out);
    return out;
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _chainSync?.cancel();
    _projectWatch?.cancel();
    _releaseCard();
    super.dispose();
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
      if (LinuxAlsa.supported) {
        // mpv lists few raw cards (often not USB DACs); the kernel lists them all.
        devices = [
          ...devices.where((d) => !d.name.startsWith('alsa/')),
          for (final o in LinuxAlsa.outputs()) OutputDevice(o.mpvName, o.name, direct: true),
        ];
      }
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
      out.add(OutputDevice(name, desc, direct: api == 'asio'));
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
        final head = await f.read(64 * 1024);
        final bits = parseSourceBits(head);
        if (bits != null) return bits;
        // MP4 files often keep their index (with ALAC's bit depth) at the end.
        final length = await f.length();
        if (length <= head.length) return null;
        await f.setPosition((length - 512 * 1024).clamp(0, length));
        return parseSourceBits(await f.read(512 * 1024));
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
    int le16(int at) => b[at] | b[at + 1] << 8;
    if (tag(0) == 'wvpk' && b.length >= 32) {
      // WavPack block header: flags at 24, bytes per sample − 1 in the low two bits.
      final flags = le32(24);
      return flags & 0x80 != 0 ? 32 : ((flags & 3) + 1) * 8;
    }
    if (tag(0) == 'MAC ' && b.length >= 64) {
      // Monkey's Audio ≥ 3.98: descriptor, then the header with the bit depth at +16.
      final version = le16(4);
      if (version >= 3980) {
        final header = le32(8);
        if (header + 18 <= b.length) return le16(header + 16);
      } else {
        // Older files: flags at 6 (8-bit / 24-bit), 16-bit otherwise.
        final flags = le16(6);
        return flags & 0x1 != 0
            ? 8
            : flags & 0x8 != 0
            ? 24
            : 16;
      }
    }
    // ALAC in MP4: the "alac" magic cookie inside the sample description.
    for (var at = b.indexOfAlac(); at >= 0 && at + 21 < b.length; at = b.indexOfAlac(at + 4)) {
      // The sample entry is named "alac" too; the cookie is the nested one: size, "alac", version/flags,
      // frameLength(4), compatibleVersion(1), bitDepth(1).
      if (tag(at + 4) == 'alac' && be32(at) == 36) return b[at + 4 + 4 + 4 + 4 + 1];
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

  /// An mpv property as text, empty when mpv has none.
  static Future<String> _read(NativePlayer p, String key) async {
    try {
      return await p.getProperty(key, waitForInitialization: false);
    } catch (_) {
      return '';
    }
  }

  /// What Stats for nerds shows beside [signalPath]: seconds of the song read
  /// ahead of the playhead, and the ReplayGain tag leveling applies ("-7.50 dB").
  Future<({double? buffered, String? gain})> nerdStats() async {
    final p = _native;
    if (p == null) return (buffered: null, gain: null);
    Future<String> g(String k) => _read(p, k);
    final track = await g('metadata/by-key/REPLAYGAIN_TRACK_GAIN');
    final gain = switch (effectiveLeveling) {
      VolumeLeveling.off => '',
      VolumeLeveling.track => track,
      // mpv falls back to the track's gain where the album has none.
      VolumeLeveling.album => switch (await g('metadata/by-key/REPLAYGAIN_ALBUM_GAIN')) {
        '' => track,
        final album => album,
      },
    };
    return (buffered: double.tryParse(await g('demuxer-cache-duration')), gain: gain.isEmpty ? null : gain);
  }

  /// One read of the live signal path, or null when nothing is playing.
  Future<SignalPath?> signalPath() async {
    final p = _native;
    if (p == null) return null;
    Future<String> g(String k) => _read(p, k);

    final inRate = int.tryParse(await g('audio-params/samplerate')) ?? 0;
    if (inRate == 0) return null;
    final af = await g('af');
    final file = await g('path');
    final output = await g('current-ao');
    final device = await g('audio-device');
    AlsaOutput? card;
    if (LinuxAlsa.supported) {
      card = LinuxAlsa.byMpvName(device) ?? (output == 'pipewire' || output == 'pulse' ? await _behind(device) : null);
    }
    return SignalPath(
      dac: card == null ? null : LinuxAlsa.hwParams(card),
      dacName: card?.name,
      sourceBits: _bitsCache[file] ??= await _sourceBits(file),
      codec: await g('audio-codec-name'),
      container: await g('file-format'),
      inFormat: await g('audio-params/format'),
      inRate: inRate,
      inChannels: int.tryParse(await g('audio-params/channel-count')) ?? 0,
      outFormat: await g('audio-out-params/format'),
      outRate: int.tryParse(await g('audio-out-params/samplerate')) ?? 0,
      outChannels: int.tryParse(await g('audio-out-params/channel-count')) ?? 0,
      output: output,
      device: device,
      exclusive: await g('audio-exclusive') == 'yes',
      filters: [
        // Volume has its own stage and the float output is the Output's format; the rest are in order.
        for (final m in RegExp(r'@(\w+):').allMatches(af).where((m) => m[1] != 'volume' && m[1] != 'output'))
          switch (m[1]) {
            'eq' => 'Equalizer',
            'preamp' => 'Equalizer headroom',
            'crossfeed' => 'Headphone crossfeed',
            'hrtf' => 'Virtual speakers (HRTF)',
            'mono' => 'Mono (both ears)',
            'monoleft' => 'Mono (left ear only)',
            'monoright' => 'Mono (right ear only)',
            'convolution' => 'Room correction (${impulseName ?? 'convolution'})',
            'plugins' => 'Audio plugins (Carla)',
            final other => other!,
          },
      ],
      // DoP holds the volume at 100% (the filter is left out).
      volume: _dop == null ? 100 * _volume : 100,
      volumeAtOutput: _volumeAtOutput,
      leveling: effectiveLeveling != VolumeLeveling.off,
      bitrate: int.tryParse(await g('audio-bitrate')),
      dopBitRate: _dop?.bitRate,
    );
  }
}

extension on Uint8List {
  /// Offset of the 4-byte box size before an "alac" atom name, or -1.
  int indexOfAlac([int from = 0]) {
    for (var i = from + 4; i + 4 <= length; i++) {
      if (this[i] == 0x61 && this[i + 1] == 0x6c && this[i + 2] == 0x61 && this[i + 3] == 0x63) return i - 4;
    }
    return -1;
  }
}
