# AGENT.md

Guide for coding agents (and people) working on OpenMusic. Read it before
changing code.

## Who it's for

OpenMusic's users are **not technical**. Every feature must work with zero
setup and one obvious control:

- YouTube Music sign-in is a single **Sign in with Google** button. Never add
  "paste your cookies", OAuth client IDs, or browser pickers.
- Power-user audio settings live under **Settings › Advanced audio**, folded
  away. Everyday ones (Equalizer, Volume leveling, Gapless, Virtual speakers,
  Crossfeed, Mono audio) sit above it in plain words.
- UI looks like a streaming app: dark, the only colour comes from real cover
  art (`AccentBuilder`), no decorative gradients, no emoji, no "AI" styling.
- Error messages the user sees (SnackBars, error lines) are one calm, plain
  sentence: "Couldn't play Song", "No internet connection. Try again." Never
  append an exception, mpv / yt-dlp output, an HTTP code or a URL; those go
  to `debugPrint`.

## Layout

```
lib/
  models/track.dart            Track (local file, cue slice or YouTube song), Collection
  services/
    player_controller.dart     Queue, shuffle (done in Dart, see below), autoplay, library
    library_store.dart         The library's own file (library.json), read and written in an isolate
    private_files.dart         The app's 0700 folder; atomic writes, 0600 secrets (the Google session)
    audio_engine.dart          Every mpv audio setting + SignalPath read-back
    lyrics.dart                .lrc / embedded tag, then YouTube Music, LRCLIB, Better Lyrics, NetEase, lyrics.ovh
    metadata.dart              Tag reading, cover art, tag editor (FLAC and MP4 in-process, others via ffmpeg)
    dlna.dart                  DLNA / UPnP: SSDP search, AVTransport control, the LAN server the TV fetches from
    cast.dart                  A cast session (DLNA or AirPlay): follows position, pause, a song's end
    airplay.dart               AirPlay 1 (RAOP) sender: mDNS search, RTSP, ALAC over RTP, timing, RSA/AES
    dop.dart                   DSF / DSDIFF reading and DoP packing (Native DSD)
    sacd.dart                  SACD ISO: TOC, audio sectors, a DSDIFF built on the fly per song
    cue_sheet.dart             Splits whole-album rips into tracks
    ytmusic_web.dart           YouTube Music InnerTube client (WEB_REMIX), public + signed in
    youtube_music_account.dart Session, library, discover pages, playlist edits, likes, radio
    youtube_audio_source.dart  Streams YouTube audio in ranged chunks (yt-dlp resolves URLs)
    ytdlp.dart                 Finds / downloads yt-dlp, resolves and caches stream URLs
    ffmpeg.dart                Finds / downloads ffmpeg (tag editor, AirPlay, casting conversions)
    system_fonts.dart          Fonts from the device's font folders (Settings › Appearance › Font)
    desktop_login.dart         Runs linux/login_helper (WebKitGTK Google sign-in window)
  ui/
    home_shell.dart            Layouts: phone tabs / desktop sidebar + one history
    navigation.dart            DesktopHistory (Back/Forward), Locations, sidebar highlight
    pages/                     One file per screen; sound_settings.dart, equalizer_page.dart…
    widgets/                   Shared widgets: controls, page_scaffold, smooth_scroll, signal_path
linux/login_helper/            C++ GTK3 + webkit2gtk-4.1 sign-in helper
linux/carla_bridge/            LADSPA plugin that runs a Carla project in mpv's filter chain (audio plugins)
third_party/                   Vendored packages (see below)
integration_test/              Real-engine tests, run in headless Weston
test/                          Unit and widget tests
```

## Library model

- There is no "source" switch: Home, Search and Library always show files on
  this device, OpenMusic playlists and YouTube Music together.
- `Track.isRemote` (has a `videoId`) means it streams. Mark those with
  `SourceMark` / `MediaCard(online: true)`. `PlayerController.downloadedCopy`
  finds a downloaded file for a YouTube song; `_sourceFor` plays that instead,
  so `isOffline(track)` is what the UI should show.
- OpenMusic playlists are `UserPlaylist` (in `models/track.dart`), stored in
  SharedPreferences (`playlists.v1`) and shown as `CollectionKind.playlist`.
- Song menus get "Remove from this playlist" from a `PlaylistEditScope` above
  them (OpenMusic playlists and the user's own YouTube Music playlists).
- Menus use `useRootNavigator: true`, and their actions use the navigator's
  context (`host` in `_TrackMenu`): the row may be rebuilt away while the
  menu is open.
- Autoplay: `PlayerController._maybeAutoplay` appends the radio of the current
  song when the queue is down to its last two songs.
- The library is saved in its own file by `LibraryStore` (it moved out of
  SharedPreferences' `library.v1`), never encoded on the UI isolate.
  Sorted lists, albums, artists and search keys come from `_LibraryViews`,
  worked out once per library change: add new derived views there, not as
  getters that sort `_library` on every call.
- `PlayerController` notifies for everything (song change, play / pause,
  buffering), several times a song. Widgets that need only part of it use
  `PlayerSelect` (rebuilds when the selected value changes),
  `VisiblePlayerBuilder` (skips pages that are covered) or
  `libraryRevision` (library and playlists only), not `PlayerScope.of`.
  `integration_test/big_library_test.dart` shows a regression (see
  Performance budget).

## How audio works

- just_audio everywhere; on **Linux, Windows and Android** its backend is
  libmpv through `just_audio_media_kit`. macOS and iOS use native players, so
  `AudioEngine.supported` is false there and the Sound settings hide.
- `third_party/just_audio_media_kit` is vendored (public domain) to expose the
  mpv player: `JustAudioMediaKit.onPlayerCreated` and `.activePlayer`.
  just_audio recreates the platform player after `stop()`, so settings are
  re-applied in `AudioEngine._applyAll` every time.
- `JustAudioMediaKit.pitch = false`: with pitch on, media_kit overwrites mpv's
  `af` property. The app owns `af` (EQ, crossfeed).
- All settings are mpv properties set in `AudioEngine._applyProps`. Options
  that only apply when the output opens (`audio-buffer`, `audio-exclusive`,
  `audio-samplerate`) need `reopen: true`, which sends `ao-reload`.
- Filters are labelled (`@eq:`, `@preamp:`, `@crossfeed:`, `@hrtf:`, `@mono:`)
  so `signalPath()` can name each stage. New DSP must use a label and add its
  name to the `switch` in `signalPath()`.
- A file in a filter graph (room correction's IR, Virtual speakers' HRIR)
  goes through `AudioEngine.graphPath` and `_lavfi` (mpv's `%n%` length
  quoting). Windows' `C:`, an apostrophe or a bracket in a folder name break
  the graph otherwise.
- Virtual speakers: FFmpeg's `headphone` with `assets/audio/hrir_kemar_48k.wav`
  (made by `tool/make_hrir.sh`, copied to a real file at first use). It runs
  at 48 kHz or the chosen output rate: left alone, `headphone` would move the
  song to the HRIR's rate with FFmpeg's default resampler.
- Mono audio uses mpv's own `format` filters, not FFmpeg's `pan`, so it needs
  nothing from the FFmpeg build. Mono turns Virtual speakers and crossfeed
  off; Virtual speakers turn crossfeed off.
- **Bit-perfect mode** must bypass every stage you add: check `bitPerfect` in
  your getter (see `eqActive`, `crossfeedActive`, `effectiveLeveling`).
- media_kit has no `setShuffleOrder`, so shuffle is done in Dart
  (`PlayerController._ordered`, `_shuffledFrom`). Never call just_audio's
  `shuffle()` / `setShuffleModeEnabled`.

### Adding an audio feature (checklist)

1. A field + setter in `AudioEngine`, saved in `load()` / `_save()`.
2. Apply it in `_applyProps` (with `reopen: true` if it's an AO option).
3. Bypass it in bit-perfect mode.
4. Show it in the signal path if it changes samples.
5. UI in `lib/ui/pages/sound_settings.dart` with `SettingTile` (it stacks the
   control under the text on narrow windows).
6. A unit test in `test/audio_features_test.dart` and a real-mpv check in
   `integration_test/zz_audio_test.dart` (read it back with `signalPath()`).

- An output device that isn't plugged in (a USB DAC) falls back to the
  system default with a note under Output device; the choice stays saved.
- **Casting** (`PlayerController.castTo`): the queue stays in `player`, paused,
  while a TV plays; `_castFollow` sends each new current song. UI must use
  the controller's `position`, `duration`, `seek`, `play`, `pause`, `volume`
  and `smoothPosition()` / `positionUpdates()`, never `player.*` directly,
  or it shows this device's paused player instead of the TV.
- `services/media_session.dart` (audio_service) mirrors the player to the
  Android notification / lock screen, Control Center and Linux MPRIS.

## YouTube Music

- InnerTube `WEB_REMIX`, **no API key** (it isn't needed, and a key-shaped
  string trips GitHub secret scanning). Signed-in requests add cookies +
  `SAPISIDHASH`; signed-out ones still get home, explore, charts, search,
  albums, playlists and radio.
- Request shapes follow [ytmusicapi](https://github.com/sigma67/ytmusicapi).
  Check its source before adding an endpoint.
- Radio / autoplay: `next` with `playlistId: RDAMVM<videoId>`.
- Playlist edits: `playlist/create`, `browse/edit_playlist` (actions
  `ACTION_ADD_VIDEO`, `ACTION_REMOVE_VIDEO` with the row's `setVideoId`,
  `ACTION_SET_PLAYLIST_NAME`, `ACTION_SET_PLAYLIST_PRIVACY`,
  `ACTION_MOVE_VIDEO_BEFORE`), `playlist/delete`, `like/like`, `like/removelike`.
- Only playlists with `musicEditablePlaylistDetailHeaderRenderer` are the
  user's own; offer edits only for those.

## Vendored packages (`third_party/`)

| Package | Why |
|---|---|
| `just_audio_media_kit` | Exposes the libmpv player (hook + `activePlayer`) |
| `audio_metadata_reader` | Its FLAC and MP4 writers dropped ReplayGain, lyrics, disc numbers and unknown tags (MP4 freeform `----` atoms) on every save; ours keep them |
| `flutter_inappwebview_linux` | Stub: the real one links WPE WebKit; Linux sign-in uses `linux/login_helper` instead |

Mark every change in vendored code with an `OpenMusic:` comment.

## Running and testing

The Flutter SDK is at `~/development/flutter/bin/flutter` (not on PATH).

```sh
flutter analyze                 # must be clean
flutter test                    # unit + widget tests
```

Integration tests drive the real app with real libmpv. **Run them only in a
headless Weston, with their own data directory**:

```sh
weston --backend=headless --socket=om-test --width=3840 --height=2160 &   # once
env -u DISPLAY WAYLAND_DISPLAY=om-test GDK_BACKEND=wayland \
  XDG_DATA_HOME=/tmp/om-test-data \
  flutter test integration_test/zz_audio_test.dart -d linux
```

- Never run them on the user's desktop session (they open windows).
- **Always** set `XDG_DATA_HOME` to a throwaway directory. The YouTube Music
  session lives under it; without it a test runs signed in as the developer
  and could change their real account.
- `zz_audio_test` routes mpv to `ao=null` (silent) and checks the signal path.
- `zz_buttons_test` talks to the live YouTube Music service, signed out.
- `zz_responsive_test` sweeps every screen across 90 window sizes; it needs a
  folder of tagged MP3s (see `s` at the top of the file).
- Add `--dart-define=SHOTS=<dir>` to save screenshots, then look at them.
- `flutter test -d linux` rebuilds `build/linux/x64/debug/bundle`. If someone
  has `flutter run` open on the project, that breaks their running app; run
  integration tests from a copy of the project instead.

### Performance budget

`tool/perf.sh` runs `integration_test/performance_test.dart` in **profile
mode** (debug-mode speed means nothing) in its own headless Weston. It plays
a generated 120-song library and wheel-scrolls Home and All Songs, then
prints `PERF …` lines and saves `build/perf/<date>.json` to compare runs.
It fails when:

- the whole app is told to rebuild more than twice a second while a song just
  plays (`PlayerController.notifyListeners`; just_audio re-emits its sequence
  state on every position tick, so only real changes may pass through), or
- a frame's build takes over 8 ms at the 90th percentile, or 40 ms at worst.

Raster (GPU) time can't be measured headless; check that on real hardware
with `flutter run --profile` and DevTools.

The same script takes another target: `tool/perf.sh
--target=integration_test/big_library_test.dart` (8240 songs: load, a folder
scan, song changes and scrolling, as `BIG …` lines) and
`--target=integration_test/cpu_test.dart` (`CPU …`: one core's share while a
song plays and while paused). Compare the old code and the new in two
copies of the project, a couple of runs each.

Memory: `tool/memory.sh [runs]` runs `integration_test/memory_test.dart` the
same way (profile, headless, fresh process per run) and prints PSS / private /
RSS at idle, playing a local FLAC, streaming YouTube and after scrolling.
Compare medians of several complete runs; debug builds are meaningless here.

## Conventions

- Match the surrounding code: comment *why*, not what; doc comments on public
  members; 120-column `dart format`.
- A failing network call shows a message (SnackBar via `PlayerController.errors`)
  and never leaves a dead button. A control that can't act is disabled, never
  silently ignored.
- Desktop navigation is one browser-style history (`DesktopHistory`): open
  screens with `ShellScope.open(page, location: …)` so the sidebar can
  highlight them. Phones keep one stack per bottom tab.
- Wheel scrolling: give new vertical scroll views a `SmoothScrollController`
  (or wrap them in `SmoothScroll`).
- Overlays above content (sticky headers) must not swallow clicks: wrap
  backgrounds in `IgnorePointer`.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat(audio): …`, `fix(ytmusic): …`). Don't commit unless asked.
- Never commit secrets, cookies or session files.
