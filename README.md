<div align="center">

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
- [Install](#install)
- [Build from source](#build-from-source)
- [YouTube Music](#youtube-music)
- [Audio](#audio)
- [Platform notes](#platform-notes)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)
- [License](#license)

## Features

- **One library.** Files on your device, your playlists and YouTube Music show up together in Home, Search and Library. YouTube Music songs carry a small cloud (they stream). Everything else plays offline, including YouTube songs you've downloaded.
- **Your music.** Reads tags and cover art from FLAC, ALAC, WAV, AIFF, MP3, AAC, Ogg, Opus, WavPack, APE, DSD (DSF/DFF) and more. Groups albums and artists, splits cue sheets and shows multi-disc albums. Includes a tag editor that keeps ReplayGain and custom tags.
- **YouTube Music, no account needed.** Home, charts, search and radio work signed out. Press **Sign in with Google** to add your liked songs, playlists and history. You can like songs and create, rename and delete playlists, and add or remove their songs, right from the app.
- **Search that answers while you type.** Suggestions and direct hits (artists, songs, albums) drop down under the search box, recent searches come back when it's empty, and results split into Songs, Artists, Albums and Playlists with a top result first.
- **Follow artists.** Artists you follow on YouTube Music show up in your library; follow or unfollow from any artist page.
- **Playlists.** OpenMusic playlists live on your device and can mix your own files with YouTube Music songs.
- **Autoplay.** When the queue ends, similar songs keep coming from YouTube Music's own *Up next* radio. You can also *Start radio* from any song.
- **Synced lyrics** that follow the song line by line: YouTube Music's own lyrics, a `.lrc` file, the file's tags, [LRCLIB](https://lrclib.net) or [Better Lyrics](https://betterlyrics.org). Click a line to jump to it.
- **Hi-fi audio** with a 10-band parametric equalizer, ReplayGain, gapless playback, headphone crossfeed and bit-perfect output. A live **signal path** shows exactly what happens to every sample. See [Audio](#audio).
- **Downloads.** Save any YouTube song or playlist for offline listening, byte for byte in the best quality YouTube serves.
- **Made for every screen.** Bottom tabs and a mini player on phones, a library sidebar and now-playing panel on desktop, tested from 240×320 up to 4K. Desktop navigation works like a browser: Back and Forward, mouse side buttons, `Alt+←/→`.
- **Full-screen and mini player** on desktop (`F11`, `Esc`), like Spotify's: the cover fills the screen, or the window shrinks to a small always-on-top player.
- **System media controls**: the Android notification and lock screen, Control Center on iOS / macOS, and MPRIS on Linux (desktop media widgets, `playerctl`).
- **Discord Rich Presence**, media keys and keyboard shortcuts (`Space`, `Ctrl+K`, `Ctrl+←/→`, `Ctrl+V` to import a copied YouTube link).

## Screenshots

| Search: your music and YouTube Music | A playlist mixing artists |
|---|---|
| ![Search](docs/screenshots/search.webp) | ![Playlist](docs/screenshots/playlist.webp) |
| **Synced lyrics** | **Equalizer** |
| ![Lyrics](docs/screenshots/lyrics.webp) | ![Equalizer](docs/screenshots/equalizer.webp) |
| **Full-screen player** | **Settings** |
| ![Full-screen player](docs/screenshots/fullscreen.webp) | ![Settings](docs/screenshots/settings.webp) |
| **Signal path** | **On a phone** |
| ![Signal path](docs/screenshots/signal-path.webp) | <img src="docs/screenshots/phone.webp" alt="Phone" width="280"> |

## Install

There are no prebuilt packages yet. [Build from source](#build-from-source) for now (it takes a few minutes).

### Linux runtime requirements

| Package (Arch) | Debian / Ubuntu | What for |
|---|---|---|
| `mpv` | `libmpv2` | Audio playback |
| `webkit2gtk-4.1` | `libwebkit2gtk-4.1-0` | The *Sign in with Google* window (optional) |
| `yt-dlp` | `yt-dlp` | YouTube streaming (optional: downloaded automatically if missing) |
| `ffmpeg` | `ffmpeg` | Editing tags of non-FLAC files (optional) |

## Build from source

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel), plus the usual desktop toolchain (Linux: `clang`, `cmake`, `ninja`, `pkg-config`, GTK 3 and `libmpv` headers).

```sh
git clone https://github.com/Araryarch67/OpenMusic.git
cd OpenMusic
flutter pub get
flutter run -d linux          # or: windows, macos, android, ios
flutter build linux --release # build/linux/x64/release/bundle/
```

After pulling changes that add packages, quit and run `flutter run` again; hot reload doesn't load new plugins.

## YouTube Music

Everything public works without an account. **Sign in with Google** opens Google's own sign-in page, in its own window on Linux and inside the app elsewhere. Once it lands on YouTube Music, the session is kept in the app's private storage on your device. OpenMusic never sees your password, and nothing is sent anywhere except to YouTube Music itself.

Changes you make (likes, playlists) go through YouTube Music's own API, so they show up in the official apps too.

## Audio

On Linux and Windows, playback runs on [libmpv](https://mpv.io). OpenMusic drives it directly:

| | |
|---|---|
| **Sound** (Settings) | Equalizer with presets and automatic headroom, volume leveling (ReplayGain per song or album), gapless playback, headphone crossfeed |
| **Advanced audio** | Output device, including direct ALSA hardware devices; **bit-perfect mode** (no DSP, no resampling, volume fixed at 100%; WASAPI exclusive on Windows, not yet tested on real hardware); **ASIO output** on Windows, built into the app's own libmpv (tested under Wine, not yet on real hardware); output sample rate; SoX resampler; buffer size |
| **Signal path** | Source codec and stored bit depth → decoder → every DSP stage → volume → resampler → output device, with a verdict: *Bit-perfect*, *Lossless to the system mixer* or *Processed* |

What's still missing (native DSD / DoP, DLNA, AirPlay, …) and how it could be built is tracked in **[Features.md](Features.md)**.

## Platform notes

| Platform | Playback | YouTube streaming / downloads |
|---|---|---|
| Linux | libmpv | yt-dlp (system one, or the official binary downloaded automatically) |
| Windows | libmpv (bundled) | yt-dlp (downloaded automatically) |
| macOS | AVPlayer | yt-dlp, AAC only (AVPlayer can't play Opus/WebM) |
| Android / iOS | ExoPlayer / AVPlayer | Built-in extractor |

The equalizer, crossfeed, leveling, output device and signal path currently need libmpv (Linux and Windows). yt-dlp needs a JavaScript runtime (Deno or Node) for some YouTube challenges.

Debug builds append every Flutter error with its full stack trace to `<app support dir>/errors.log` (on Linux, `~/.local/share/dev.openmusic.openmusic/errors.log`).

## Contributing

Bug reports, ideas and pull requests are welcome. Start with **[CONTRIBUTING.md](CONTRIBUTING.md)**. **[AGENT.md](AGENT.md)** explains how the code is laid out and how to test it (it's written for coding agents, but people find it useful too).

## Acknowledgements

OpenMusic stands on the shoulders of:

- [mpv](https://mpv.io) / [media_kit](https://github.com/media-kit/media-kit) and [just_audio](https://github.com/ryanheise/just_audio) for playback
- [FFmpeg](https://ffmpeg.org) for decoding, filters and resampling (with [SoX's resampler](https://sourceforge.net/projects/soxr/))
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [youtube_explode_dart](https://github.com/Hexer10/youtube_explode_dart) for YouTube audio
- [ytmusicapi](https://github.com/sigma67/ytmusicapi), whose documentation of YouTube Music's API this app follows
- [LRCLIB](https://lrclib.net) and [Better Lyrics](https://betterlyrics.org) for free synced lyrics
- [audio_metadata_reader](https://github.com/ClementBeal/audio_metadata_reader) for tags

OpenMusic is not affiliated with YouTube, Google or Discord.

## License

OpenMusic is free software: you can redistribute it and/or modify it under the terms of the **GNU Affero General Public License v3.0** as published by the Free Software Foundation. See [LICENSE](LICENSE).

If you run a modified version for others over a network, the AGPL asks you to offer them its source too.

Vendored packages in [`third_party/`](third_party) keep their own licenses (the Unlicense for `just_audio_media_kit`, MIT for `audio_metadata_reader`, GPLv3 for Steinberg's `asiosdk`).
