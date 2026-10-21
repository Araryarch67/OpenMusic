# Audiophile features: status

What works today, and what is still missing, partial or blocked. Keep this
file in sync when a feature lands (see [AGENT.md](AGENT.md)).

Desktop audio (Linux, Windows) goes through libmpv, configured in
`lib/services/audio_engine.dart`. Android, iOS and macOS use just_audio's
native players (ExoPlayer / AVPlayer), which none of the DSP below reaches.

## Not working yet

| Feature | Status | Why it's missing | Likely way to build it |
|---|---|---|---|
| SACD ISO | Not started | FFmpeg has no SACD ISO demuxer | Extract with `sacd_extract` (or port its demuxer) to DSF tracks at import time |
| VST plugins | Not started | mpv can't host VST | A native plugin host (e.g. Carla, or an LV2/VST3 host) as a separate process in the signal path; heavy |
| AirPlay | Not started | AirPlay 2 needs FairPlay-style pairing; classic RAOP needs ALAC + RTSP + encryption | RAOP (AirPlay 1) sender; most AirPlay 2 receivers still accept it |
| Roon Ready | Blocked | Roon only certifies vetted hardware/software partners | Apply to Roon's partner programme; nothing to build alone |
| Qobuz / Tidal | Blocked | Both need partner API credentials and terms | Apply for partner access; then a source like the YouTube Music one |

## Partial

| Feature | What works | What's missing |
|---|---|---|
| ASIO output (Windows) | The app ships its own libmpv (`windows/libmpv/libmpv-2.dll`, built by `tool/build_libmpv_windows.sh`) with a native **ASIO audio output** (`third_party/mpv_asio`, on Steinberg's GPLv3 ASIO SDK). Installed drivers show under **Output device** as "ASIO: …"; the driver's callback pulls audio straight from mpv, Int16/Int32/Float32/Float64 are written into the driver's buffers as they are (24-bit and right-aligned formats are converted), the device follows each song's rate and mpv converts when the driver can't run at it. Tested under Wine with a test driver in all four sample formats, and in the full app (`tool/test_asio_wine.sh`, `tool/build_windows_wine.sh`) | Never run on real Windows hardware with a real ASIO driver. No channel routing; no buffer-size or control-panel button; drivers show in the list only once something has played; for 24-bit drivers the signal path reports 32-bit |
| Signal path indicator | Codec, stored bit depth (FLAC, WAV, AIFF, WavPack, APE, ALAC), decoder format, DSP stages, volume, resampling, output, and on Linux **what the DAC actually receives** (kernel `hw_params`), including PipeWire's own resampling | On Windows, what the DAC receives (only what mpv sends to WASAPI / ASIO) |
| Native DSD (DoP) | **Native DSD (DoP)** in Settings › Advanced audio (with Bit-perfect mode): DSF and uncompressed DSDIFF files go to the DAC as DoP (DSD64 as 24-bit / 176.4 kHz, DSD128 at 352.8 kHz...), packed on the fly with byte-range seeking; volume is held at 100% while a DSD song plays, and the signal path says "Native DSD". Checked through the real libmpv: its output is the DoP stream byte for byte (`integration_test/zz_dop_test.dart`) | Never tried on a DAC that decodes DoP (a DAC without DoP plays faint hiss, so it is off by default). Not for DST-compressed DSDIFF or DSD inside cue sheets (those still play as PCM); no native (non-DoP) DSD over ALSA `DSD_U32` |
| UPnP / DLNA casting | **Play on** (cast button in the player bar) finds TVs, speakers and receivers on the network (SSDP) and moves the music there, from where it was; play, pause, seek, next / previous, the queue and volume go to the device, and its position, pause from its remote and the end of each song come back every second. Local MP3 / FLAC / M4A / WAV are served as they are with byte ranges; other formats and cue-sheet slices are converted to FLAC on the fly by ffmpeg (DSD at 176.4 kHz); YouTube songs go as AAC through the app (most TVs can't decode Opus). Tested against a simulated renderer, in unit tests and in the real app (`integration_test/zz_cast_test.dart`) | Never tried on a real TV or speaker. The audio settings (EQ, crossfeed, bit-perfect) don't apply to what the device plays; converted songs can't be byte-seeked, so a seek restarts the conversion; no gapless between songs on the device |
| Desktop audio engine on macOS | Plays through AVPlayer | Equalizer, crossfeed, leveling, output device, bit-perfect and signal path are Linux/Windows only |

## Working

Bit-perfect mode on Linux, **verified on a USB DAC** (KTMicro CDS.KT): it takes
the card behind the current output over from PipeWire (D-Bus device
reservation, like JACK) and plays straight to `hw:`; a 24-bit / 96 kHz FLAC
reaches the DAC as `S24_3LE` at 96 kHz and a CD-quality file as `S16_LE` at
44.1 kHz, so the sample rate follows each file. The system's default output
is restored afterwards, and the card is released even if the app is killed
(`integration_test/zz_dac_test.dart`, opt-in). WASAPI Exclusive / bit-perfect
on Windows (`audio-exclusive=yes` when **Bit-perfect mode** or **Exclusive
mode** is on, volume pinned at 100%), tested on real Windows hardware. Also: output
device picker, output sample-rate override, SoX (VHQ) resampler when
libswresample has it (high-quality swr settings otherwise), buffer size,
gapless playback, ReplayGain (track / album), volume applied in 64-bit float (or bypassed in bit-perfect mode), room correction (impulse response through FFmpeg's `afir`), 10-band parametric equalizer
with presets and automatic headroom, headphone crossfeed, lossless and hi-res
formats (anything FFmpeg decodes; tested with 24-bit / 96 kHz FLAC), cue
sheets, multi-disc albums, tag editor that keeps ReplayGain and custom tags
(tested on FLAC, MP3, Ogg and M4A with AAC or ALAC, where freeform atoms such as
ReplayGain and MusicBrainz IDs are kept; WAV, AIFF, WavPack and MKA go through
the same ffmpeg path but are untested), embedded and sidecar cover art, online cover art (**Find online** in the tag
editor: MusicBrainz + Cover Art Archive, 1200 px, embedded on save), synced lyrics
(LRC files, embedded, YouTube Music's Lyrics tab, LRCLIB, Better Lyrics, NetEase Cloud Music,
lyrics.ovh), with pronunciation (romanization) and translation
under each line (Google Translate's free endpoint, Better Lyrics' translation
service as fallback).
