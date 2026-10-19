import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/player_controller.dart';
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
