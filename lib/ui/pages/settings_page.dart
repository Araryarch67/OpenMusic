import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/discord_presence.dart';
import '../../services/player_controller.dart';
import '../../services/youtube_importer.dart';
import '../../services/ytdlp.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/page_scaffold.dart';
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

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    final muted = text.bodySmall?.copyWith(color: AppColors.textSecondary);

    return PageScaffold(
      title: 'Settings',
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
            child: Text('Settings', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
        ),
        SliverToBoxAdapter(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: pad - 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListenableBuilder(
                      listenable: c.ytMusic,
                      builder: (context, _) {
                        final account = c.ytMusic;
                        return SettingTile(
                          title: const Text('YouTube Music account'),
                          subtitle: Text(
                            account.isSignedIn
                                ? 'Signed in${account.accountName == null ? '' : ' as ${account.accountName}'}'
                                : 'Not signed in. Search and the public home work without an account.',
                            style: muted,
                          ),
                          control: account.isSignedIn
                              ? TextButton(onPressed: account.signOut, child: const Text('Disconnect'))
                              : FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: Colors.black,
                                  ),
                                  onPressed: account.connecting ? null : () => signInToYoutubeMusic(context),
                                  child: const Text('Sign in with Google'),
                                ),
                        );
                      },
                    ),
                    if (DiscordPresence.supported)
                      SwitchListTile(
                        title: const Text('Discord Rich Presence'),
                        subtitle: Text('Show what you\'re listening to on your Discord profile', style: muted),
                        value: c.discordEnabled,
                        onChanged: c.setDiscordEnabled,
                      ),
                    if (YtDlp.supported)
                      FutureBuilder<String?>(
                        future: _ytdlp,
                        builder: (context, snap) => ListTile(
                          title: const Text('yt-dlp'),
                          subtitle: Text(
                            snap.connectionState != ConnectionState.done
                                ? 'Checking…'
                                : snap.data ??
                                      'Not available. Install it (e.g. pacman -S yt-dlp) for YouTube downloads.',
                            style: muted,
                          ),
                        ),
                      ),
                    FutureBuilder<Directory>(
                      future: _downloads,
                      builder: (context, snap) => ListTile(
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
                    const SoundSettings(),
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
