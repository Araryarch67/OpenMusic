# OpenMusic

A cross-platform music player built with Flutter: Android, iOS, Linux, Windows and macOS.

## Features

- **Two sources, one switch: Local | YouTube Music.** Home, Search and Library follow the active source.
  - **Local:** reads tags and cover art (MP3, FLAC, M4A, OGG, Opus, WAV, AIFF), groups by album and artist.
  - **YouTube Music:** liked music, recent plays and your playlists, streamed on demand; any song can be downloaded for offline.
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

## YouTube Music sign-in

- **Desktop (easiest):** log in at music.youtube.com in your browser, then in OpenMusic switch the source to *YouTube Music* and pick that browser. yt-dlp reads the session from the browser on each request; OpenMusic never stores cookies or passwords.
- **Advanced / mobile:** your own Google OAuth client ("TVs and Limited Input devices") with the official YouTube Data API v3. This gives liked music and playlists, but no history.

## Platform notes

| Platform | Playback | YouTube downloads / streaming |
|---|---|---|
| Linux | libmpv (`mpv` package) | yt-dlp: the system one if installed, otherwise the app downloads the official binary |
| Windows | libmpv (bundled) | yt-dlp (auto-downloaded) |
| macOS | AVPlayer | yt-dlp (auto-downloaded), AAC only (AVPlayer can't play Opus/WebM) |
| Android / iOS | ExoPlayer / AVPlayer | In-app extractor only; currently limited by YouTube's PO-token checks |

yt-dlp needs a JavaScript runtime (Deno or Node) for some YouTube challenges.

## Debugging

Debug builds append every Flutter error with its full stack trace to
`<app support dir>/errors.log` (on Linux, `~/.local/share/dev.openmusic.openmusic/errors.log`).
