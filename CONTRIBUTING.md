# Contributing to OpenMusic

Thanks for helping. A few things make reviews quick.

## Before you start

- **Bugs:** open an issue with your platform, what you did, what you expected
  and what happened. Debug builds log every error to
  `<app support dir>/errors.log`; attach the relevant part.
- **Features:** for anything big, open an issue first so we can agree on the
  approach. Audiophile features have a status table in [Features.md](Features.md).

## Who we build for

OpenMusic's users are not technical. A feature should work with zero setup and
one obvious control. Power-user options belong under *Settings › Advanced
audio*. The look follows streaming apps: dark, colour only from cover art.

## Code

- Read [AGENT.md](AGENT.md) first: layout, the audio engine, YouTube Music
  endpoints, and the testing rules.
- Match the surrounding code; run `dart format -l 120` on what you touch.
- `flutter analyze` must be clean and `flutter test` must pass.
- New behaviour comes with a test. Integration tests run in a headless Weston
  with their own `XDG_DATA_HOME` (see AGENT.md); never against your real account.

## Commits and pull requests

- [Conventional Commits](https://www.conventionalcommits.org/):
  `feat(audio): …`, `fix(ytmusic): …`, `docs: …`.
- One topic per pull request. Describe what changed and how you tested it, and
  add a screenshot for UI changes.
- Never commit secrets, cookies or session files.

## License

By contributing you agree that your contributions are licensed under the
[GNU AGPL v3.0](LICENSE), like the rest of OpenMusic.
