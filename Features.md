# Audiophile features: status

What works today, and what is still missing, partial or blocked. Keep this
file in sync when a feature lands (see [AGENT.md](AGENT.md)).

Desktop audio (Linux, Windows) goes through libmpv, configured in
`lib/services/audio_engine.dart`. Android, iOS and macOS use just_audio's
native players (ExoPlayer / AVPlayer), which none of the DSP below reaches.

## Not working yet

| Feature | Status | Why it's missing | Likely way to build it |
|---|---|---|---|
| Native DSD output (DoP / native DSD to the DAC) | Not started | FFmpeg decodes DSF/DFF to PCM (DSD64 → 352.8 kHz float); mpv can't pass DSD through | DoP packing (DSD bits in 24-bit PCM frames with 0x05/0xFA markers) in a custom output path, sent bit-perfect to an ALSA hw / WASAPI exclusive device |
| SACD ISO | Not started | FFmpeg has no SACD ISO demuxer | Extract with `sacd_extract` (or port its demuxer) to DSF tracks at import time |
| VST plugins | Not started | mpv can't host VST | A native plugin host (e.g. Carla, or an LV2/VST3 host) as a separate process in the signal path; heavy |
| UPnP / DLNA casting | Not started | No code yet | Control point in Dart: SSDP M-SEARCH, device XML, `SetAVTransportURI` / `Play`, plus a local HTTP server with range support for files and streams (YouTube via AAC so renderers can decode it) |
| AirPlay | Not started | AirPlay 2 needs FairPlay-style pairing; classic RAOP needs ALAC + RTSP + encryption | RAOP (AirPlay 1) sender; most AirPlay 2 receivers still accept it |
| Roon Ready | Blocked | Roon only certifies vetted hardware/software partners | Apply to Roon's partner programme; nothing to build alone |
| Qobuz / Tidal | Blocked | Both need partner API credentials and terms | Apply for partner access; then a source like the YouTube Music one |
| Tag editing for MP4 / M4A / ALAC | Disabled on purpose | The FLAC writer is patched to keep every tag, but ffmpeg's MP4 muxer drops freeform atoms (ReplayGain, MusicBrainz) | Patch `third_party/audio_metadata_reader`'s MP4 writer to keep unknown `----` atoms, then enable `m4a` in `Metadata.canEditTags` |
| Online hi-res cover art | Not started | Only embedded art, sidecar files and "Change cover" are supported | Cover Art Archive / MusicBrainz lookup by album + artist, saved as `cover.jpg` |

## Partial

| Feature | What works | What's missing |
|---|---|---|
| ASIO output (Windows) | The app ships its own libmpv (`windows/libmpv/libmpv-2.dll`, built by `tool/build_libmpv_windows.sh`) with a native **ASIO audio output** (`third_party/mpv_asio`, on Steinberg's GPLv3 ASIO SDK). Installed drivers show under **Output device** as "ASIO: …"; the driver's callback pulls audio straight from mpv, Int16/Int32/Float32/Float64 are written into the driver's buffers as they are (24-bit and right-aligned formats are converted), the device follows each song's rate and mpv converts when the driver can't run at it. Tested under Wine with a test driver in all four sample formats, and in the full app (`tool/test_asio_wine.sh`, `tool/build_windows_wine.sh`) | Never run on real Windows hardware with a real ASIO driver. No channel routing; no buffer-size or control-panel button; drivers show in the list only once something has played; for 24-bit drivers the signal path reports 32-bit |
| WASAPI Exclusive / bit-perfect (Windows) | `audio-exclusive=yes` is set when **Bit-perfect mode** or **Exclusive mode** is on; volume pinned at 100% | Never run on real Windows hardware; needs a check with a DAC |
| Signal path indicator | Codec, stored bit depth (FLAC, WAV, AIFF, WavPack, APE, ALAC), decoder format, DSP stages, volume, resampling, output, and on Linux **what the DAC actually receives** (kernel `hw_params`), including PipeWire's own resampling | On Windows, what the DAC receives (only what mpv sends to WASAPI / ASIO) |
| DSD files (DSF / DFF) | Play as high-rate PCM; signal path says "DSD64 → PCM 352.8 kHz" | No DoP / native output (see above) |
| Desktop audio engine on macOS | Plays through AVPlayer | Equalizer, crossfeed, leveling, output device, bit-perfect and signal path are Linux/Windows only |

## Working

Bit-perfect mode on Linux, **verified on a USB DAC** (KTMicro CDS.KT): it takes
the card behind the current output over from PipeWire (D-Bus device
reservation, like JACK) and plays straight to `hw:`; a 24-bit / 96 kHz FLAC
reaches the DAC as `S24_3LE` at 96 kHz and a CD-quality file as `S16_LE` at
44.1 kHz, so the sample rate follows each file. The system's default output
is restored afterwards, and the card is released even if the app is killed
(`integration_test/zz_dac_test.dart`, opt-in). Also: output
device picker, output sample-rate override, SoX (VHQ) resampler when
libswresample has it (high-quality swr settings otherwise), buffer size,
gapless playback, ReplayGain (track / album), volume applied in 64-bit float (or bypassed in bit-perfect mode), room correction (impulse response through FFmpeg's `afir`), 10-band parametric equalizer
with presets and automatic headroom, headphone crossfeed, lossless and hi-res
formats (anything FFmpeg decodes; tested with 24-bit / 96 kHz FLAC), cue
sheets, multi-disc albums, tag editor that keeps ReplayGain and custom tags
(tested on FLAC, MP3 and Ogg; WAV, AIFF, WavPack and MKA go through the same
ffmpeg path but are untested), embedded and sidecar cover art, synced lyrics
(LRC files, embedded, YouTube Music's Lyrics tab, LRCLIB, Better Lyrics).
