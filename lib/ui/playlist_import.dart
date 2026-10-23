import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/track.dart';
import '../services/player_controller.dart';
import '../services/playlist_transfer.dart';
import '../services/youtube_music_account.dart';
import 'theme.dart';

/// Where an imported playlist was saved.
typedef ImportedPlaylist = ({String title, String? youtubeId, UserPlaylist? local});

/// "Import a playlist": asks for a Spotify, Apple Music or Deezer link, finds
/// its songs in YouTube Music and saves them as a playlist: in the YouTube
/// Music library when signed in, as an OpenMusic playlist otherwise.
/// Returns the playlist once the user asks to open it.
Future<ImportedPlaylist?> askToImportPlaylist(BuildContext context) async {
  final c = PlayerScope.read(context);
  final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
  if (!context.mounted) return null;
  final transfer = PlaylistTransfer();
  try {
    return await showDialog<ImportedPlaylist>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PlaylistImportDialog(
        initial: copied != null && PlaylistTransfer.looksLikeLink(copied) ? copied : null,
        signedIn: c.ytMusic.canEdit,
        read: transfer.read,
        search: c.ytMusic.searchSongs,
        videos: c.ytMusic.searchVideos,
        save: (title, tracks) => _save(c, title, tracks),
      ),
    );
  } finally {
    transfer.close();
  }
}

/// Signed in: a YouTube Music playlist (the songs go in 100 at a time).
/// Otherwise an OpenMusic playlist of the streamed songs.
Future<ImportedPlaylist> _save(PlayerController c, String title, List<Track> tracks) async {
  if (!c.ytMusic.canEdit) return (title: title, youtubeId: null, local: c.createPlaylist(title, tracks: tracks));
  final id = await c.ytMusic.createPlaylist(title, tracks: tracks.take(100).toList());
  for (var i = 100; i < tracks.length; i += 100) {
    await c.ytMusic.addToPlaylist(id, tracks.skip(i).take(100).toList());
  }
  return (title: title, youtubeId: id, local: null);
}

enum _Step { link, reading, matching, saving, done }

/// The steps of an import: the link, reading it, finding the songs, the result.
class PlaylistImportDialog extends StatefulWidget {
  const PlaylistImportDialog({
    super.key,
    required this.initial,
    required this.signedIn,
    required this.read,
    required this.search,
    required this.videos,
    required this.save,
  });

  final String? initial;

  /// Where it's saved: the YouTube Music library, or OpenMusic playlists.
  final bool signedIn;
  final Future<ForeignPlaylist> Function(String link) read;
  final Future<List<Track>> Function(String query) search;
  final Future<List<Track>> Function(String query) videos;
  final Future<ImportedPlaylist> Function(String title, List<Track> tracks) save;

  @override
  State<PlaylistImportDialog> createState() => _PlaylistImportDialogState();
}

class _PlaylistImportDialogState extends State<PlaylistImportDialog> {
  late final link = TextEditingController(text: widget.initial);
  var step = _Step.link;
  String? error;
  ForeignPlaylist? playlist;
  var done = 0;

  /// Bumped by every start and cancel; an import whose number is old stops.
  var run = 0;
  List<ForeignSong> missing = const [];
  ImportedPlaylist? result;
  int saved = 0;

  bool get valid => PlaylistTransfer.looksLikeLink(link.text);

  @override
  void dispose() {
    run++;
    link.dispose();
    super.dispose();
  }

  Future<void> start() async {
    if (!valid) return;
    final me = ++run;
    bool stale() => !mounted || me != run;
    setState(() {
      step = _Step.reading;
      error = null;
      done = 0;
    });
    try {
      final p = await widget.read(link.text);
      if (stale()) return;
      setState(() {
        playlist = p;
        step = _Step.matching;
      });
      final r = await PlaylistTransfer.match(
        p.songs,
        widget.search,
        videos: widget.videos,
        cancelled: stale,
        onProgress: (n) {
          if (!stale()) setState(() => done = n);
        },
      );
      if (stale()) return;
      if (r.found.isEmpty) throw const PlaylistTransferError('None of its songs are on YouTube Music.');
      setState(() => step = _Step.saving);
      final where = await widget.save(p.title, r.found);
      if (!mounted) return;
      setState(() {
        result = where;
        saved = r.found.length;
        missing = r.missing;
        step = _Step.done;
      });
    } catch (e) {
      if (stale()) return;
      setState(() {
        error = switch (e) {
          PlaylistTransferError(:final message) => message,
          _ => YoutubeMusicAccount.describe(e),
        };
        step = _Step.link;
      });
    }
  }

  /// Stops looking songs up and goes back to the link.
  void cancel() => setState(() {
    run++;
    step = _Step.link;
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final secondary = text.bodySmall?.copyWith(color: AppColors.textSecondary);
    final p = playlist;
    final signedIn = widget.signedIn;
    return AlertDialog(
      title: Text(switch (step) {
        _Step.link => 'Import a playlist',
        _Step.done => 'Imported "${result!.title}"',
        _ => p?.title ?? 'Import a playlist',
      }),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: switch (step) {
            _Step.link => [
              const Text('Paste a playlist link from Spotify, Apple Music or Deezer.'),
              const SizedBox(height: 4),
              Text(
                signedIn
                    ? 'It becomes a playlist in your YouTube Music library.'
                    : 'It becomes an OpenMusic playlist of YouTube Music songs.',
                style: secondary,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: link,
                autofocus: widget.initial == null,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() => error = null),
                onSubmitted: (_) => start(),
                decoration: InputDecoration(
                  labelText: 'Playlist link',
                  border: const OutlineInputBorder(),
                  errorMaxLines: 3,
                  errorText:
                      error ??
                      (link.text.trim().isNotEmpty && !valid
                          ? 'That isn\'t a Spotify, Apple Music or Deezer playlist link'
                          : null),
                ),
              ),
            ],
            _Step.reading => [
              Text('Reading the playlist…', style: secondary),
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            _Step.matching || _Step.saving => [
              Text(
                step == _Step.saving ? 'Saving…' : 'Finding songs in YouTube Music: $done of ${p!.songs.length}',
                style: secondary,
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: step == _Step.saving || p == null || p.songs.isEmpty ? null : done / p.songs.length,
              ),
            ],
            _Step.done => [
              Text(
                '$saved of ${p!.total} songs added${result!.youtubeId != null ? ' to your YouTube Music library' : ''}.',
              ),
              if (p.total > p.songs.length) ...[
                const SizedBox(height: 8),
                Text(
                  '${p.service} only shows the first ${p.songs.length} songs without signing in, '
                  'so the rest were left out.',
                  style: secondary,
                ),
              ],
              if (missing.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  missing.length == 1
                      ? '1 song isn\'t on YouTube Music:'
                      : '${missing.length} songs aren\'t on YouTube Music:',
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final s in missing)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text('$s', maxLines: 1, overflow: TextOverflow.ellipsis, style: secondary),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          },
        ),
      ),
      actions: switch (step) {
        _Step.link => [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: valid ? start : null, child: const Text('Import')),
        ],
        _Step.saving => const [],
        _Step.done => [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton(onPressed: () => Navigator.pop(context, result), child: const Text('Open playlist')),
        ],
        _ => [TextButton(onPressed: cancel, child: const Text('Cancel'))],
      },
    );
  }
}
