<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/icon/openmusic-transparent.svg">
  <img src="assets/icon/openmusic-transparent-light.svg" width="128" height="128" alt="OpenMusic logo">
</picture>

# OpenMusic

**Your own music and YouTube Music in one player, with hi-fi audio.**

A free, open-source music player for Linux, Windows, macOS, Android and iOS, built with Flutter.

[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
![Platforms](https://img.shields.io/badge/platforms-Linux%20%7C%20Windows%20%7C%20macOS%20%7C%20Android%20%7C%20iOS-555)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

![OpenMusic home](docs/screenshots/home.webp)

</div>

## Table of contents

- [Features](#features)
- [Screenshots](#screenshots)
- [Build from source](#build-from-source)
- [YouTube Music](#youtube-music)
- [Audio](#audio)
- [Platform notes](#platform-notes)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)
- [License](#license)

## Features

| Feature | In short |
|---|---|
| **One library** | Your files, your playlists and YouTube Music, together |
| **Every format** | FLAC, ALAC, WAV, AIFF, MP3, AAC, Ogg, Opus, WavPack, APE, DSD, SACD ISO, cue sheets |
| **YouTube Music** | Works signed out; **Sign in with Google** for likes, playlists and history |
| **Synced lyrics** | Line by line, with pronunciation and translation |
| **Playlists** | Mix your files with YouTube songs; import from Spotify, Apple Music or Deezer |
| **Autoplay and radio** | Similar songs keep coming when the queue ends |
| **Equalizer** | 10-band parametric, presets, headroom so it never clips |
| **Virtual speakers** | Headphones sound like two speakers in front of you (HRTF) |
| **Mono audio** | Both sides as one, in both ears or just one: for headphones with a dead side |
| **Crossfeed** | Gentler stereo on headphones |
| **Room correction** | Load an impulse response, e.g. from REW |
| **Volume leveling** | ReplayGain, per song or per album |
| **Gapless** | No silence between songs that flow into each other |
| **Bit-perfect and DSD** | The file to your DAC untouched, native DSD (DoP), exclusive mode |
| **Audio plugins** | VST, LV2 and CLAP through Carla (Linux) |
| **Signal path** | What happens to every sample, from file to speaker |
| **Play on TVs and speakers** | DLNA / UPnP and AirPlay |
| **Downloads** | YouTube songs and playlists, offline |
| **Tag editor** | Keeps ReplayGain and custom tags |
| **Make it yours** | Catppuccin, Nord, Gruvbox, Dracula and more, any font, cover-art colours |
| **Every screen** | Phone, tablet and desktop layouts, mini and full-screen player |
| **System controls** | Lock screen, notification, Control Center, MPRIS, media keys, Discord |
| **Fast** | A YouTube song starts in about 0.3 s |

## Screenshots

| Search: your music and YouTube Music | A playlist mixing artists |
|---|---|
| ![Search](docs/screenshots/search.webp) | ![Playlist](docs/screenshots/playlist.webp) |
| **Synced lyrics** | **Equalizer** |
| ![Lyrics](docs/screenshots/lyrics.webp) | ![Equalizer](docs/screenshots/equalizer.webp) |
| **Full-screen player** | **Settings** |
| ![Full-screen player](docs/screenshots/fullscreen.webp) | ![Settings](docs/screenshots/settings.webp) |
| **Virtual speakers and Mono audio** | **Signal path** |
| ![Playback settings](docs/screenshots/sound.webp) | ![Signal path](docs/screenshots/signal-path.webp) |
| **On a phone** | |
| <img src="docs/screenshots/phone.webp" alt="Phone" width="280"> | |

## Build from source

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel), plus the usual desktop toolchain (Linux: `clang`, `cmake`, `ninja`, `pkg-config`, GTK 3 and `libmpv` headers).

```sh
git clone https://github.com/Araryarch67/OpenMusic.git
cd OpenMusic
flutter pub get
flutter run -d linux          # or: windows, macos, android, ios
flutter build linux --release # build/linux/x64/release/bundle/
```

On macOS and iOS the first build also builds libmpv from source (`tool/build_libmpv_apple.sh`, about ten minutes; needs Homebrew's `meson`, `ninja`, `nasm` and `pkgconf`).

After pulling changes that add packages, quit and run `flutter run` again; hot reload doesn't load new plugins.

## YouTube Music

Everything public works without an account. **Sign in with Google** opens Google's own sign-in page, in its own window on Linux and inside the app elsewhere. Once it lands on YouTube Music, the session is kept in the app's private storage on your device. OpenMusic never sees your password, and nothing is sent anywhere except to YouTube Music itself.

Changes you make (likes, playlists) go through YouTube Music's own API, so they show up in the official apps too.

## Audio

Every platform plays through [libmpv](https://mpv.io), with OpenMusic's own build of it where the stock one lacks filters (Windows, Android, macOS, iOS; see `tool/build_libmpv_*.sh`). So the sound settings are the same everywhere:

| | |
|---|---|
| **Playback** (Settings) | Equalizer with presets and automatic headroom, volume leveling (ReplayGain per song or album), gapless playback, **Virtual speakers** (MIT's KEMAR HRTF: two speakers at ±30°), headphone crossfeed, **Mono audio** (both ears, left only or right only) |
| **Hi-fi audio** | Room correction (an impulse response); output sample rate; SoX resampler; buffer size. On desktop also: output device, including direct ALSA hardware on Linux; **bit-perfect mode**; **exclusive mode** (WASAPI on Windows, Core Audio hog mode on macOS); **Native DSD (DoP)** for DSF, DSDIFF and SACD songs; **ASIO** on Windows; **audio plugins** through [Carla](https://kx.studio/Applications:Carla) on Linux |
| **Play on** | DLNA / UPnP renderers and classic AirPlay speakers, found on the network. Files the device can't play (DSD, cue-sheet songs, WavPack...) are converted to FLAC on the fly, YouTube songs go as AAC; AirPlay gets ALAC |
| **Signal path** | Source codec and stored bit depth → decoder → every DSP stage → volume → resampler → output device, with a verdict: *Bit-perfect*, *Lossless to the system mixer* or *Processed* |

Not yet tried on real hardware: ASIO, exclusive mode, and casting to real TVs and speakers (tested under Wine, against a simulated renderer and shairport-sync); on macOS and iOS, everything beyond the automated checks GitHub's Macs run.

## Platform notes

| | Linux | Windows | macOS | Android | iOS |
|---|---|---|---|---|---|
| Sound settings, signal path | ✓ | ✓ | ✓ | ✓ | ✓ |
| Output device, bit-perfect, DSD, exclusive | ✓ | ✓ | ✓ | – | – |
| Add a folder | ✓ | ✓ | ✓ | ✓ | – |
| AirPlay, TV conversions, tag editor for MP3 / Ogg… (FFmpeg) | ✓ | ✓ | ✓ | – | – |
| Discord | ✓ | ✓ | ✓ | – | – |
| Audio plugins (Carla), see-through window | ✓ | – | – | – | – |
| ASIO | – | ✓ | – | – | – |

Android and iOS give apps no device choice or exclusive output, no Discord connection and no way to run FFmpeg; iOS apps can't scan a folder outside their own. YouTube streams through YouTube's player API everywhere, with yt-dlp (desktop) or a built-in extractor (phones) as the fallback; yt-dlp needs a JavaScript runtime (Deno or Node) for some YouTube challenges.

Nothing else needs installing. FFmpeg (for the tag editor's MP3 / Ogg / WAV…, AirPlay and formats a TV can't play) is a system one when there is one; otherwise the official static build (gyan.dev on Windows, johnvansickle.com on Linux, Martin Riedl's on macOS, about 40 MB) is downloaded the first time it's needed, checked against its published checksum and kept in the app's folder.

The macOS app isn't signed by Apple: the first time, open it from System Settings › Privacy & Security › **Open Anyway**. The iOS `.ipa` is unsigned too; sideload it with AltStore or Sideloadly.

Debug builds append every Flutter error with its full stack trace to `<app support dir>/errors.log` (on Linux, `~/.local/share/dev.openmusic.openmusic/errors.log`).

## Contributing

Bug reports, ideas and pull requests are welcome. Start with **[CONTRIBUTING.md](CONTRIBUTING.md)**. **[AGENT.md](AGENT.md)** explains how the code is laid out and how to test it (it's written for coding agents, but people find it useful too).

## Acknowledgements

OpenMusic stands on the shoulders of:

- [mpv](https://mpv.io) / [media_kit](https://github.com/media-kit/media-kit) and [just_audio](https://github.com/ryanheise/just_audio) for playback
- [FFmpeg](https://ffmpeg.org) for decoding, filters and resampling (with [SoX's resampler](https://sourceforge.net/projects/soxr/))
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [youtube_explode_dart](https://github.com/Hexer10/youtube_explode_dart) for YouTube audio
- [ytmusicapi](https://github.com/sigma67/ytmusicapi), whose documentation of YouTube Music's API this app follows
- [LRCLIB](https://lrclib.net), [Better Lyrics](https://betterlyrics.org), NetEase Cloud Music and [lyrics.ovh](https://lyrics.ovh) for free lyrics
- [audio_metadata_reader](https://github.com/ClementBeal/audio_metadata_reader) for tags
- Bill Gardner and Keith Martin's [KEMAR HRTF measurements](https://sound.media.mit.edu/resources/KEMAR.html) (MIT Media Lab) for Virtual speakers

OpenMusic is not affiliated with YouTube, Google or Discord.

## License

OpenMusic is free software: you can redistribute it and/or modify it under the terms of the **GNU Affero General Public License v3.0** as published by the Free Software Foundation. See [LICENSE](LICENSE).

If you run a modified version for others over a network, the AGPL asks you to offer them its source too.

Vendored packages in [`third_party/`](third_party) keep their own licenses (the Unlicense for `just_audio_media_kit`, MIT for `audio_metadata_reader` and the `media_kit_libs_*` packages, GPLv3 for Steinberg's `asiosdk`).
