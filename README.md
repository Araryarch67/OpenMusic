# OpenMusic

A cross-platform music player built with Flutter: Android, iOS, Linux, Windows and macOS.

## Features

- **Your music and YouTube Music in one place.** Home, Search and Library show both together. YouTube Music songs carry a small cloud (they stream, so they need internet); everything else, including downloaded YouTube songs, plays offline.
  - **Files on this device:** reads tags and cover art (FLAC, ALAC, WAV, AIFF, MP3, M4A, Ogg, Opus, WavPack, APE, DSD…), groups by album and artist, splits cue sheets, shows multi-disc albums.
  - **YouTube Music:** home, charts, search and radio without an account; liked songs, playlists and history once signed in. Like songs and create, rename, delete and edit YouTube Music playlists from the app.
- **OpenMusic playlists:** kept on this device, and they can mix your own files with YouTube Music songs.
- **Autoplay:** when the queue ends, similar songs keep coming (YouTube Music's own "Up next" radio). *Start radio* from any YouTube song.
- **Lyrics:** synced, line by line (a `.lrc` next to the file, lyrics in the tags, or LRCLIB).
- **Sound:** equalizer, volume leveling (ReplayGain), gapless, headphone crossfeed; under *Advanced audio* bit-perfect mode, output device, sample rate, resampler and buffer. See [Features.md](Features.md).
- **YouTube import:** paste a video or playlist link (or press Ctrl+V anywhere outside a text field). Audio is saved byte-for-byte in the best quality YouTube serves (Opus ~130–160 kbps or AAC 128 kbps, AAC 256 kbps with Premium). YouTube has no lossless audio.
- **Fast downloads:** several songs at once and parallel range requests; the Downloads page shows size, speed and time left.
- **Discord Rich Presence:** "Listening to" with progress bar, cover art and a YouTube Music button (toggle in Settings).
- **Responsive layout:** bottom tabs and a mini player on phones, a library sidebar on tablets, plus a now-playing panel on wide screens. Tested from 240×320 up to 3840×2160, including live resizing.
- **Custom title bar** on desktop (the window is undecorated; works with tiling WMs).
- **Keyboard:** `Space` play/pause, `Ctrl+←/→` previous/next, `Ctrl+K` search, `Ctrl+V` import a copied YouTube link, plus media keys.

## Run

```sh
flutter pub get
flutter run -d linux     # or: windows, macos, android, ios
```

After pulling new code that adds packages, quit and `flutter run` again; hot reload doesn't load new plugins.

## YouTube Music

Home, Explore, charts, search and radio work straight away, no account needed. To add your liked music, playlists and history, press **Sign in with Google**. Google's own sign-in page opens (in its own window on Linux, inside the app elsewhere); once it lands on YouTube Music the session is kept in the app's private storage. OpenMusic never sees your password.

On Linux the sign-in window needs WebKitGTK (`webkit2gtk-4.1`) at build time; without it the app still builds, just without sign-in.

## Platform notes

| Platform | Playback | YouTube downloads / streaming |
|---|---|---|
| Linux | libmpv (`mpv` package) | yt-dlp: the system one if installed, otherwise the app downloads the official binary |
| Windows | libmpv (bundled) | yt-dlp (auto-downloaded) |
| macOS | AVPlayer | yt-dlp (auto-downloaded), AAC only (AVPlayer can't play Opus/WebM) |
| Android / iOS | ExoPlayer / AVPlayer | In-app extractor |

yt-dlp needs a JavaScript runtime (Deno or Node) for some YouTube challenges.

## Debugging

Debug builds append every Flutter error with its full stack trace to
`<app support dir>/errors.log` (on Linux, `~/.local/share/dev.openmusic.openmusic/errors.log`).
