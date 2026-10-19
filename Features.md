# Audiophile features: status

What works today, and what is still missing, partial or blocked. Keep this
file in sync when a feature lands (see [AGENT.md](AGENT.md)).

Desktop audio (Linux, Windows) goes through libmpv, configured in
`lib/services/audio_engine.dart`. Android, iOS and macOS use just_audio's
native players (ExoPlayer / AVPlayer), which none of the DSP below reaches.

## Not working yet

| Feature | Status | Why it's missing | Likely way to build it |
|---|---|---|---|
| ASIO output (Windows) | Not started | mpv has no ASIO output driver, and the ASIO SDK is Steinberg-licensed | A separate native output (e.g. PortAudio built with ASIO, or BASS + BASSASIO) fed decoded PCM, or a custom libmpv build. Until then **WASAPI Exclusive** (bit-perfect mode) is the Windows path |
| Native DSD output (DoP / native DSD to the DAC) | Not started | FFmpeg decodes DSF/DFF to PCM (DSD64 → 352.8 kHz float); mpv can't pass DSD through | DoP packing (DSD bits in 24-bit PCM frames with 0x05/0xFA markers) in a custom output path, sent bit-perfect to an ALSA hw / WASAPI exclusive device |
| SACD ISO | Not started | FFmpeg has no SACD ISO demuxer | Extract with `sacd_extract` (or port its demuxer) to DSF tracks at import time |
| Convolution / room correction | Not started | No IR loader or UI yet | FFmpeg's `afir` lavfi filter in the `af` chain, plus a WAV impulse-response picker in Advanced audio |
| VST plugins | Not started | mpv can't host VST | A native plugin host (e.g. Carla, or an LV2/VST3 host) as a separate process in the signal path; heavy |
| UPnP / DLNA casting | In progress | SSDP discovery + AVTransport SOAP not finished | Control point in Dart: SSDP M-SEARCH, device XML, `SetAVTransportURI` / `Play`, plus a local HTTP server with range support for files and streams (YouTube via AAC so renderers can decode it) |
| AirPlay | Not started | AirPlay 2 needs FairPlay-style pairing; classic RAOP needs ALAC + RTSP + encryption | RAOP (AirPlay 1) sender; most AirPlay 2 receivers still accept it |
| Roon Ready | Blocked | Roon only certifies vetted hardware/software partners | Apply to Roon's partner programme; nothing to build alone |
| Qobuz / Tidal | Blocked | Both need partner API credentials and terms | Apply for partner access; then a source like the YouTube Music one |
| Tag editing for MP4 / M4A / ALAC | Disabled on purpose | The FLAC writer is patched to keep every tag, but ffmpeg's MP4 muxer drops freeform atoms (ReplayGain, MusicBrainz) | Patch `third_party/audio_metadata_reader`'s MP4 writer to keep unknown `----` atoms, then enable `m4a` in `Metadata.canEditTags` |
| Online hi-res cover art | Not started | Only embedded art, sidecar files and "Change cover" are supported | Cover Art Archive / MusicBrainz lookup by album + artist, saved as `cover.jpg` |

## Partial

| Feature | What works | What's missing |
|---|---|---|
| WASAPI Exclusive / bit-perfect (Windows) | `audio-exclusive=yes` is set when **Bit-perfect mode** or **Exclusive mode** is on; volume pinned at 100% | Never run on real Windows hardware; needs a check with a DAC |
| Automatic sample-rate switching (Linux) | mpv opens the output at the file's rate; a **direct** ALSA device follows every file | Through PipeWire the graph rate only changes if the user's PipeWire allows it (`default.clock.allowed-rates`); the app can't set that |
| 64-bit float volume | mpv scales in float internally; **Bit-perfect mode** bypasses digital volume entirely | No explicit 64-bit volume stage |
| Signal path indicator | Codec, stored bit depth (FLAC/WAV/AIFF headers), decoder format, DSP stages, volume, resampling, output driver/device, bit-perfect verdict | Bit depth for WavPack / APE / ALAC isn't read; the system mixer's own rate (PipeWire) isn't shown |
| DSD files (DSF / DFF) | Play as high-rate PCM; signal path says "DSD64 → PCM 352.8 kHz" | No DoP / native output (see above) |
| Desktop audio engine on macOS | Plays through AVPlayer | Equalizer, crossfeed, leveling, output device, bit-perfect and signal path are Linux/Windows only |

## Working

Bit-perfect mode (Linux direct ALSA device, Windows WASAPI exclusive), output
device picker, output sample-rate override, SoX (VHQ) resampler when
libswresample has it (high-quality swr settings otherwise), buffer size,
gapless playback, ReplayGain (track / album), 10-band parametric equalizer
with presets and automatic headroom, headphone crossfeed, lossless and hi-res
formats (anything FFmpeg decodes; tested with 24-bit / 96 kHz FLAC), cue
sheets, multi-disc albums, tag editor that keeps ReplayGain and custom tags
(tested on FLAC, MP3 and Ogg; WAV, AIFF, WavPack and MKA go through the same
ffmpeg path but are untested), embedded and sidecar cover art, synced lyrics
(LRC files, embedded, LRCLIB).
