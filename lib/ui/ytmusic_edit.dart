import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/track.dart';
import '../services/player_controller.dart';
import '../services/youtube_importer.dart';
import '../services/youtube_music_account.dart';
import '../services/ytmusic_web.dart';
import 'theme.dart';

/// Marks the songs below as rows of a playlist the user can edit (an
/// OpenMusic playlist or their own YouTube Music one), so each song's menu
/// can offer "Remove from this playlist".
class PlaylistEditScope extends InheritedWidget {
  const PlaylistEditScope({super.key, required this.canRemove, required this.remove, required super.child});

  final bool Function(Track track) canRemove;
  final Future<void> Function(BuildContext context, Track track) remove;

  static PlaylistEditScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlaylistEditScope>();

  @override
  bool updateShouldNotify(PlaylistEditScope old) => true;
}

/// Runs a library change and reports how it went, in plain words.
Future<bool> _report(BuildContext context, Future<void> Function() change, String done) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await change();
    messenger.showSnackBar(SnackBar(content: Text(done)));
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
}

Future<void> toggleLike(BuildContext context, Track track) {
  final account = PlayerScope.read(context).ytMusic;
  final liked = account.isLiked(track);
  return _report(
    context,
    () => account.setLiked(track, !liked),
    liked ? 'Removed from Liked music' : 'Added to Liked music',
  );
}

/// Name + privacy for a new playlist (or a rename when [initialTitle] is set).
Future<({String title, PlaylistPrivacy privacy, PlaylistHome home})?> askPlaylistName(
  BuildContext context, {
  String? initialTitle,
  PlaylistPrivacy initialPrivacy = PlaylistPrivacy.private,
  bool askPrivacy = true,
  bool offerYoutube = false,
}) => showDialog<({String title, PlaylistPrivacy privacy, PlaylistHome home})>(
  context: context,
  builder: (_) => _PlaylistNameDialog(
    initialTitle: initialTitle,
    initialPrivacy: initialPrivacy,
    askPrivacy: askPrivacy,
    offerYoutube: offerYoutube,
  ),
);

/// Owns its text controller, so it lives exactly as long as the dialog
/// (including its closing animation).
class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.initialTitle,
    required this.initialPrivacy,
    required this.askPrivacy,
    required this.offerYoutube,
  });

  final String? initialTitle;
  final PlaylistPrivacy initialPrivacy;
  final bool askPrivacy;
  final bool offerYoutube;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final name = TextEditingController(text: widget.initialTitle);
  late var privacy = widget.initialPrivacy;
  var home = PlaylistHome.openMusic;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void submit() {
    final t = name.text.trim();
    if (t.isNotEmpty) Navigator.pop(context, (title: t, privacy: privacy, home: home));
  }

  @override
  Widget build(BuildContext context) {
    final initialTitle = widget.initialTitle;
    final askPrivacy = widget.askPrivacy;
    final offerYoutube = widget.offerYoutube;
    return AlertDialog(
      title: Text(initialTitle == null ? 'New playlist' : 'Rename playlist'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => submit(),
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
            ),
            if (offerYoutube) ...[
              const SizedBox(height: 16),
              SegmentedButton<PlaylistHome>(
                segments: const [
                  ButtonSegment(
                    value: PlaylistHome.openMusic,
                    icon: Icon(Icons.offline_pin_outlined),
                    label: Text('OpenMusic'),
                  ),
                  ButtonSegment(
                    value: PlaylistHome.youtubeMusic,
                    icon: Icon(Icons.cloud_outlined),
                    label: Text('YouTube Music'),
                  ),
                ],
                selected: {home},
                onSelectionChanged: (v) => setState(() => home = v.first),
              ),
              const SizedBox(height: 8),
              Text(
                home == PlaylistHome.openMusic
                    ? 'Kept on this device. Can mix your own files and YouTube Music songs.'
                    : 'Saved to your YouTube Music account, on all your devices.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
              ),
            ],
            if (askPrivacy || home == PlaylistHome.youtubeMusic) ...[
              const SizedBox(height: 16),
              SegmentedButton<PlaylistPrivacy>(
                segments: [for (final p in PlaylistPrivacy.values) ButtonSegment(value: p, label: Text(p.label))],
                selected: {privacy},
                onSelectionChanged: (v) => setState(() => privacy = v.first),
              ),
              const SizedBox(height: 8),
              Text(switch (privacy) {
                PlaylistPrivacy.private => 'Only you can see it.',
                PlaylistPrivacy.unlisted => 'Anyone with the link can see it.',
                PlaylistPrivacy.public => 'Anyone can find and see it.',
              }, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: submit, child: Text(initialTitle == null ? 'Create' : 'Save')),
      ],
    );
  }
}

/// Where a new playlist goes.
enum PlaylistHome { openMusic, youtubeMusic }

/// "New playlist": an OpenMusic playlist on this device by default. Signed in,
/// it can be made in YouTube Music instead, but only when every song is from
/// YouTube Music (files from this device can't go there).
Future<void> createPlaylist(BuildContext context, {List<Track> tracks = const []}) async {
  final c = PlayerScope.read(context);
  final canYoutube = c.ytMusic.canEdit && tracks.every((t) => t.isRemote);
  final answer = await askPlaylistName(context, askPrivacy: false, offerYoutube: canYoutube);
  if (answer == null || !context.mounted) return;
  if (answer.home == PlaylistHome.youtubeMusic) {
    await _report(
      context,
      () => c.ytMusic.createPlaylist(answer.title, privacy: answer.privacy, tracks: tracks),
      'Created "${answer.title}" in YouTube Music',
    );
    return;
  }
  c.createPlaylist(answer.title, tracks: tracks);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        tracks.isEmpty ? 'Created "${answer.title}"' : 'Created "${answer.title}" with ${tracks.length} songs',
      ),
    ),
  );
}

/// "Add to playlist": OpenMusic playlists, then (for YouTube songs, signed in)
/// the YouTube Music ones, each marked with where it lives.
Future<void> addToPlaylist(BuildContext context, List<Track> tracks) async {
  final c = PlayerScope.read(context);
  final account = c.ytMusic;
  final remoteOk = account.canEdit && tracks.every((t) => t.isRemote);
  final remote = remoteOk
      ? (await account.library().catchError(
          (Object _) => const YoutubeMusicLibrary(liked: [], playlists: [], recent: []),
        )).playlists
      : const <RemotePlaylist>[];
  if (!context.mounted) return;
  final text = Theme.of(context).textTheme;
  final choice = await showDialog<Object>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Add to playlist'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, #create),
          child: const ListTile(leading: Icon(Icons.add_rounded), title: Text('New playlist')),
        ),
        for (final p in c.playlists)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, p),
            child: ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('OpenMusic • ${p.tracks.length} songs', style: text.bodySmall),
            ),
          ),
        for (final p in remote)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, p),
            child: ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                p.count == 0 ? 'YouTube Music' : 'YouTube Music • ${p.count} songs',
                style: text.bodySmall,
              ),
            ),
          ),
      ],
    ),
  );
  if (!context.mounted) return;
  final what = tracks.length == 1 ? 'Added' : 'Added ${tracks.length} songs';
  switch (choice) {
    case #create:
      return createPlaylist(context, tracks: tracks);
    case final UserPlaylist p:
      final n = c.addToPlaylist(p.id, tracks);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(n == 0 ? 'Already in ${p.name}' : '$what to ${p.name}')));
    case final RemotePlaylist p:
      await _report(context, () => account.addToPlaylist(p.id, tracks), '$what to ${p.title}');
  }
}

Future<void> removeFromPlaylist(BuildContext context, Track track) async {
  final scope = PlaylistEditScope.maybeOf(context);
  if (scope != null) await scope.remove(context, track);
}

/// Removing a row from one of the user's YouTube Music playlists.
Future<bool> removeFromRemotePlaylist(BuildContext context, String playlistId, Track track, String rowId) => _report(
  context,
  () => PlayerScope.read(context).ytMusic.removeFromPlaylist(playlistId, track, rowId),
  'Removed from this playlist',
);

/// "Invite friends": turns on collaboration and hands over the link to send.
/// A private playlist has to become unlisted first, so that's asked.
/// Returns whether the playlist is now shared.
Future<bool> inviteToPlaylist(BuildContext context, String playlistId, PlaylistPrivacy? privacy) async {
  final account = PlayerScope.read(context).ytMusic;
  final messenger = ScaffoldMessenger.of(context);
  if (privacy == PlaylistPrivacy.private) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Make it unlisted?'),
        content: const Text(
          'Friends can only join a playlist that isn\'t private. It will become unlisted: '
          'hidden from search, but anyone with the link can see it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Make unlisted')),
        ],
      ),
    );
    if (ok != true) return false;
  }
  final String link;
  try {
    link = await account.inviteLink(playlistId, privacy: privacy);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
  await Clipboard.setData(ClipboardData(text: link));
  if (!context.mounted) return true;
  await showDialog<void>(
    context: context,
    builder: (_) => _InviteDialog(link: link),
  );
  return true;
}

class _InviteDialog extends StatelessWidget {
  const _InviteDialog({required this.link});

  final String link;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Invite friends'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The link is copied. Send it to your friends: anyone who opens it can add songs.'),
            const SizedBox(height: 16),
            DecoratedBox(
              decoration: BoxDecoration(color: AppColors.hover, borderRadius: BorderRadius.circular(6)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(link, maxLines: 2, style: text.bodySmall),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: link));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
          },
          child: const Text('Copy again'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}

/// "Stop sharing": every friend loses access and old links stop working.
Future<bool> stopSharingPlaylist(BuildContext context, String playlistId) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Stop sharing?'),
      content: const Text('Friends won\'t be able to add songs any more, and old invite links stop working.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Stop sharing')),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  return _report(
    context,
    () => PlayerScope.read(context).ytMusic.stopCollaboration(playlistId),
    'Only you can add songs now',
  );
}

/// Asks for a friend's invite link (filled in from the clipboard when one is
/// there) and joins it. Returns the playlist's id once joined.
Future<String?> askToJoinPlaylist(BuildContext context) async {
  final account = PlayerScope.read(context).ytMusic;
  final messenger = ScaffoldMessenger.of(context);
  final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
  if (!context.mounted) return null;
  final link = await showDialog<String>(
    context: context,
    builder: (_) => _JoinDialog(initial: copied != null && YtMusicWeb.parseInvite(copied) != null ? copied : null),
  );
  if (link == null) return null;
  try {
    return await account.joinPlaylist(link);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return null;
  }
}

class _JoinDialog extends StatefulWidget {
  const _JoinDialog({required this.initial});

  final String? initial;

  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<_JoinDialog> {
  late final link = TextEditingController(text: widget.initial);
  late bool valid = widget.initial != null;

  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }

  void submit() {
    if (valid) Navigator.pop(context, link.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join a shared playlist'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Paste the invite link a friend sent you. You\'ll both be able to add songs.'),
            const SizedBox(height: 16),
            TextField(
              controller: link,
              autofocus: widget.initial == null,
              textInputAction: TextInputAction.done,
              onChanged: (v) => setState(() => valid = YtMusicWeb.parseInvite(v) != null),
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                labelText: 'Invite link',
                border: const OutlineInputBorder(),
                errorText: link.text.trim().isNotEmpty && !valid ? 'That isn\'t an invite link' : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: valid ? submit : null, child: const Text('Join')),
      ],
    );
  }
}

/// The ♥ button for the song that's playing.
class LikeButton extends StatelessWidget {
  const LikeButton({super.key, required this.track, this.size = 20, this.color});

  final Track track;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final account = PlayerScope.of(context).ytMusic;
    if (!track.isRemote || !account.canEdit) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) {
        final liked = account.isLiked(track);
        return IconButton(
          tooltip: liked ? 'Remove from Liked music' : 'Add to Liked music',
          iconSize: size,
          color: liked ? AppColors.accent : color,
          onPressed: () => toggleLike(context, track),
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
            child: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, key: ValueKey(liked)),
          ),
        );
      },
    );
  }
}

/// "Follow" / "Following" for a YouTube Music artist (signed in through the app).
class FollowButton extends StatelessWidget {
  const FollowButton({super.key, required this.artistId, required this.name});

  final String artistId;
  final String name;

  @override
  Widget build(BuildContext context) {
    final account = PlayerScope.of(context).ytMusic;
    if (!account.canEdit) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) {
        final following = account.isFollowing(artistId);
        return OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textPrimary,
            side: BorderSide(color: following ? AppColors.textSecondary : AppColors.textPrimary),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 18),
          ),
          onPressed: () => _report(
            context,
            () => account.setFollowing(artistId, !following),
            following ? 'Unfollowed $name' : 'Following $name',
          ),
          child: Text(following ? 'Following' : 'Follow'),
        );
      },
    );
  }
}

/// Download for offline, for a streamed song: an arrow, a progress ring while
/// it downloads (tap to stop), a check once it's on the device.
class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key, required this.track, this.size = 20, this.color});

  final Track track;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    if (!track.isRemote) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: c.youtube,
      builder: (context, _) {
        final job = c.youtube.jobFor(track.videoId!);
        if (c.downloadedCopy(track) != null || job?.status == DownloadStatus.done) {
          return IconButton(
            tooltip: 'Downloaded',
            iconSize: size,
            color: AppColors.accent,
            onPressed: null,
            disabledColor: AppColors.accent,
            icon: const Icon(Icons.download_done_rounded),
          );
        }
        if (job != null && job.isActive) {
          return IconButton(
            tooltip: 'Stop download',
            iconSize: size,
            onPressed: () => c.youtube.cancel(job),
            icon: SizedBox.square(
              dimension: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: job.status == DownloadStatus.downloading && job.progress > 0 ? job.progress : null,
                    strokeWidth: 2,
                    color: AppColors.accent,
                    backgroundColor: AppColors.textPrimary.withValues(alpha: 0.24),
                  ),
                  Icon(Icons.stop_rounded, size: size * 0.5, color: color),
                ],
              ),
            ),
          );
        }
        return IconButton(
          tooltip: job?.status == DownloadStatus.failed ? 'Download failed, try again' : 'Download',
          iconSize: size,
          color: job?.status == DownloadStatus.failed ? Theme.of(context).colorScheme.error : color,
          onPressed: () {
            c.youtube.enqueueTracks([track]);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Downloading ${track.title}…')));
          },
          icon: Icon(job?.status == DownloadStatus.failed ? Icons.error_outline_rounded : Icons.download_rounded),
        );
      },
    );
  }
}
