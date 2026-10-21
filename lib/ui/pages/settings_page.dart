import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/discord_presence.dart';
import '../../services/lyrics.dart';
import '../../services/player_controller.dart';
import '../../services/youtube_importer.dart';
import '../../services/ytdlp.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/page_scaffold.dart';
import '../../services/audio_engine.dart';
import 'appearance_settings.dart';
import 'sound_settings.dart';
import 'youtube_music_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<String?> _ytdlp = _ytdlpVersion();
  late final Future<Directory> _downloads = YoutubeImporter.downloadsDir();

  static Future<String?> _ytdlpVersion() async {
    final exe = await YtDlp.executable();
    if (exe == null) return null;
    final r = await Process.run(exe, ['--version']);
    return r.exitCode == 0 ? '${(r.stdout as String).trim()} ($exe)' : null;
  }

  final _keys = {for (final s in _Section.values) s: GlobalKey()};

  void _jump(_Section s) {
    final target = _keys[s]!.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    final muted = settingsMuted(context);
    final sections = [
      _Section.account,
      _Section.appearance,
      _Section.playback,
      if (AudioEngine.supported) _Section.advanced,
      _Section.downloads,
      _Section.integrations,
    ];

    Widget body(_Section s) => switch (s) {
      _Section.account => ListenableBuilder(
        listenable: c.ytMusic,
        builder: (context, _) {
          final account = c.ytMusic;
          return SettingsCard(
            children: [
              ListTile(
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor: AppColors.hover,
                  foregroundImage: account.avatarUrl == null ? null : NetworkImage(account.avatarUrl!),
                  child: const Icon(Icons.person_rounded, color: AppColors.textSecondary),
                ),
                title: Text(account.isSignedIn ? account.accountName ?? 'YouTube Music' : 'YouTube Music'),
                subtitle: Text(
                  account.isSignedIn
                      ? 'Signed in. Your likes, playlists and followed artists are here.'
                      : 'Not signed in. Search and the public home work without an account.',
                  style: muted,
                ),
                trailing: account.isSignedIn
                    ? TextButton(onPressed: account.signOut, child: const Text('Disconnect'))
                    : FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                        onPressed: account.connecting ? null : () => signInToYoutubeMusic(context),
                        child: const Text('Sign in with Google'),
                      ),
              ),
            ],
          );
        },
      ),
      _Section.appearance => const AppearanceSettings(),
      _Section.playback => const PlaybackSettings(),
      _Section.advanced => const AdvancedAudioSettings(),
      _Section.downloads => SettingsCard(
        children: [
          FutureBuilder<Directory>(
            future: _downloads,
            builder: (context, snap) => ListTile(
              leading: const Icon(Icons.folder_rounded),
              title: const Text('Downloads folder'),
              subtitle: Text(snap.data?.path ?? '…', style: muted),
              trailing: snap.hasData && !Platform.isIOS && !Platform.isAndroid
                  ? IconButton(
                      tooltip: 'Open folder',
                      onPressed: () => launchUrl(Uri.directory(snap.data!.path)),
                      icon: const Icon(Icons.folder_open_rounded),
                    )
                  : null,
            ),
          ),
          if (YtDlp.supported)
            FutureBuilder<String?>(
              future: _ytdlp,
              builder: (context, snap) => ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('YouTube downloader (yt-dlp)'),
                subtitle: Text(
                  snap.connectionState != ConnectionState.done
                      ? 'Checking…'
                      : snap.data ?? 'Not available. Install it (e.g. pacman -S yt-dlp) for YouTube downloads.',
                  style: muted,
                ),
              ),
            ),
        ],
      ),
      _Section.integrations => SettingsCard(
        children: [
          if (DiscordPresence.supported)
            SwitchListTile(
              secondary: const Icon(Icons.discord),
              title: const Text('Discord Rich Presence'),
              subtitle: Text('Show what you\'re listening to on your Discord profile', style: muted),
              value: c.discordEnabled,
              onChanged: c.setDiscordEnabled,
            ),
          ListTile(
            leading: const Icon(Icons.key_rounded),
            title: const Text('Better Lyrics API key'),
            subtitle: Text(
              LyricsService.betterLyricsKey == null
                  ? 'Optional. Lets Better Lyrics find lyrics it hasn\'t saved yet, if you have a key.'
                  : 'Added. Better Lyrics can find lyrics it hasn\'t saved yet.',
              style: muted,
            ),
            trailing: TextButton(
              onPressed: () async {
                await showDialog<void>(context: context, builder: (_) => const _BetterLyricsKeyDialog());
                if (mounted) setState(() {});
              },
              child: Text(LyricsService.betterLyricsKey == null ? 'Add' : 'Change'),
            ),
          ),
        ],
      ),
    };

    return PageScaffold(
      title: 'Settings',
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 0),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Settings', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 14),
                    // Jump to a section.
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final s in sections)
                          ActionChip(avatar: Icon(s.icon, size: 18), label: Text(s.label), onPressed: () => _jump(s)),
                      ],
                    ),
                    const SizedBox(height: 28),
                    for (final s in sections) SettingsSection(key: _keys[s], title: s.label, child: body(s)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _Section {
  account('Account', Icons.person_outline_rounded),
  appearance('Appearance', Icons.palette_outlined),
  playback('Playback', Icons.play_circle_outline_rounded),
  advanced('Hi-fi audio', Icons.tune_rounded),
  downloads('Downloads', Icons.download_rounded),
  integrations('Integrations', Icons.extension_outlined);

  const _Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Paste, check and save (or remove) a Better Lyrics API key.
class _BetterLyricsKeyDialog extends StatefulWidget {
  const _BetterLyricsKeyDialog();

  @override
  State<_BetterLyricsKeyDialog> createState() => _BetterLyricsKeyDialogState();
}

class _BetterLyricsKeyDialogState extends State<_BetterLyricsKeyDialog> {
  late final _key = TextEditingController(text: LyricsService.betterLyricsKey ?? '');
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save(String? key) async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final ok = await LyricsService.setBetterLyricsKey(key);
      if (!mounted) return;
      if (ok) return Navigator.pop(context);
      setState(() => _error = 'Better Lyrics says this key isn\'t valid.');
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn\'t reach Better Lyrics to check the key. Try again.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Better Lyrics API key'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Without a key, lyrics from Better Lyrics still work for every song it has saved. '
            'Better Lyrics isn\'t giving out new keys right now.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _key,
            autofocus: true,
            obscureText: true,
            enabled: !_checking,
            decoration: InputDecoration(
              labelText: 'API key',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: _error,
              errorMaxLines: 2,
            ),
            onSubmitted: (v) => _save(v),
          ),
        ],
      ),
    ),
    actions: [
      if (LyricsService.betterLyricsKey != null)
        TextButton(onPressed: _checking ? null : () => _save(null), child: const Text('Remove')),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ListenableBuilder(
        listenable: _key,
        builder: (context, _) => FilledButton(
          onPressed: _checking || _key.text.trim().isEmpty ? null : () => _save(_key.text),
          child: Text(_checking ? 'Checking…' : 'Save'),
        ),
      ),
    ],
  );
}
