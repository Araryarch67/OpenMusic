import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/discord_presence.dart';
import '../../services/lyrics.dart';
import '../../services/player_controller.dart';
import '../../services/youtube_importer.dart';
import '../../services/ytdlp.dart';
import '../navigation.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/page_scaffold.dart';
import '../../services/audio_engine.dart';
import 'appearance_settings.dart';
import 'sound_settings.dart';
import 'youtube_music_page.dart';

/// One page of settings, opened from the list on [SettingsPage].
enum SettingsTopic {
  account('Account', Icons.person_outline_rounded, 'YouTube Music sign-in'),
  appearance('Appearance', Icons.palette_outlined, 'Theme, accent colour, background, text size'),
  playback('Playback', Icons.play_circle_outline_rounded, 'Autoplay, equalizer, volume leveling, crossfeed'),
  advanced('Hi-fi audio', Icons.tune_rounded, 'Output device, bit-perfect mode, sample rate'),
  downloads('Downloads', Icons.download_rounded, 'Where songs are saved, YouTube downloader'),
  integrations('Integrations', Icons.extension_outlined, 'Discord, lyrics services');

  const SettingsTopic(this.label, this.icon, this.summary);
  final String label;
  final IconData icon;
  final String summary;

  static List<SettingsTopic> get available => [
    for (final t in values)
      if (t != advanced || AudioEngine.supported) t,
  ];
}

/// The list of settings pages.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final muted = settingsMuted(context);
    return _SettingsFrame(
      title: 'Settings',
      child: ListenableBuilder(
        listenable: c.ytMusic,
        builder: (context, _) => SettingsCard(
          children: [
            for (final t in SettingsTopic.available)
              ListTile(
                leading: t == SettingsTopic.account
                    ? CircleAvatar(
                        radius: 18,
                        backgroundColor: AppColors.hover,
                        foregroundImage: c.ytMusic.avatarUrl == null ? null : NetworkImage(c.ytMusic.avatarUrl!),
                        child: Icon(t.icon, color: AppColors.textSecondary, size: 20),
                      )
                    : SizedBox.square(dimension: 36, child: Icon(t.icon)),
                title: Text(t.label),
                subtitle: Text(
                  t == SettingsTopic.account && c.ytMusic.isSignedIn
                      ? 'Signed in as ${c.ytMusic.accountName ?? 'YouTube Music'}'
                      : t.summary,
                  style: muted,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => shell.open(SettingsTopicPage(topic: t), location: Locations.settingsTopic(t.name)),
              ),
          ],
        ),
      ),
    );
  }
}

/// One settings topic on its own page.
class SettingsTopicPage extends StatefulWidget {
  const SettingsTopicPage({super.key, required this.topic});

  final SettingsTopic topic;

  @override
  State<SettingsTopicPage> createState() => _SettingsTopicPageState();
}

class _SettingsTopicPageState extends State<SettingsTopicPage> {
  late final Future<String?> _ytdlp = _ytdlpVersion();
  late final Future<Directory> _downloads = YoutubeImporter.downloadsDir();

  static Future<String?> _ytdlpVersion() async {
    final exe = await YtDlp.executable();
    if (exe == null) return null;
    final r = await Process.run(exe, ['--version']);
    return r.exitCode == 0 ? '${(r.stdout as String).trim()} ($exe)' : null;
  }

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final muted = settingsMuted(context);

    final body = switch (widget.topic) {
      SettingsTopic.account => ListenableBuilder(
        listenable: c.ytMusic,
        builder: (context, _) {
          final account = c.ytMusic;
          return SettingsCard(
            children: [
              // Stacks the button under the text on narrow windows.
              SettingTile(
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor: AppColors.hover,
                  foregroundImage: account.avatarUrl == null ? null : NetworkImage(account.avatarUrl!),
                  child: Icon(Icons.person_rounded, color: AppColors.textSecondary),
                ),
                title: Text(account.isSignedIn ? account.accountName ?? 'YouTube Music' : 'YouTube Music'),
                subtitle: Text(
                  account.isSignedIn
                      ? 'Signed in. Your likes, playlists and followed artists are here.'
                      : 'Not signed in. Search and the public home work without an account.',
                  style: muted,
                ),
                control: account.isSignedIn
                    ? TextButton(onPressed: account.signOut, child: const Text('Disconnect'))
                    : FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.inverse,
                          foregroundColor: AppColors.onInverse,
                        ),
                        onPressed: account.connecting ? null : () => signInToYoutubeMusic(context),
                        child: const Text('Sign in with Google'),
                      ),
              ),
            ],
          );
        },
      ),
      SettingsTopic.appearance => const AppearanceSettings(),
      SettingsTopic.playback => const PlaybackSettings(),
      SettingsTopic.advanced => const AdvancedAudioSettings(),
      SettingsTopic.downloads => SettingsCard(
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
      SettingsTopic.integrations => SettingsCard(
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

    return _SettingsFrame(title: widget.topic.label, inTopic: true, child: body);
  }
}

/// A settings page: on topic pages a "Settings › Topic" breadcrumb, then the heading and [child].
class _SettingsFrame extends StatelessWidget {
  const _SettingsFrame({required this.title, required this.child, this.inTopic = false});

  final String title;
  final bool inTopic;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    return PageScaffold(
      title: title,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 28),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (inTopic) _Breadcrumb(current: title),
                    Text(title, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 24),
                    child,
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

/// "Settings › Appearance": the first crumb opens the list of settings.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.current});

  final String current;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        label: 'Settings, then $current',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CrumbLink(
              label: 'Settings',
              style: style,
              onTap: () => ShellScope.of(context).open(const SettingsPage(), location: Locations.settings),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textMuted),
            ),
            Flexible(
              child: Text(
                current,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A crumb that underlines on hover, like a link.
class _CrumbLink extends StatefulWidget {
  const _CrumbLink({required this.label, required this.style, required this.onTap});

  final String label;
  final TextStyle? style;
  final VoidCallback onTap;

  @override
  State<_CrumbLink> createState() => _CrumbLinkState();
}

class _CrumbLinkState extends State<_CrumbLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: Text(
        widget.label,
        style: widget.style?.copyWith(
          color: _hover ? AppColors.textPrimary : AppColors.textSecondary,
          decoration: _hover ? TextDecoration.underline : null,
          decorationColor: AppColors.textPrimary,
        ),
      ),
    ),
  );
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
