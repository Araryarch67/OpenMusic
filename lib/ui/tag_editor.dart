import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/metadata.dart';
import '../services/player_controller.dart';
import 'theme.dart';
import 'widgets/controls.dart';

/// "Edit info" for a local file: title, artist, album, numbers and cover art.
Future<void> showTagEditor(BuildContext context, Track track) async {
  final c = PlayerScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  TagEdit tags;
  try {
    tags = await Metadata.readTags(track);
  } catch (e) {
    debugPrint('Reading tags failed: $e');
    messenger.showSnackBar(const SnackBar(content: Text('Couldn\'t read this song\'s info')));
    return;
  }
  if (!context.mounted) return;
  final saved = await showDialog<TagEdit>(
    context: context,
    builder: (_) => _TagEditorDialog(track: track, tags: tags),
  );
  if (saved == null) return;
  try {
    await c.editTags(track, saved);
    messenger.showSnackBar(const SnackBar(content: Text('Saved')));
  } catch (e) {
    debugPrint('Saving tags failed: $e');
    messenger.showSnackBar(const SnackBar(content: Text('Couldn\'t save the changes')));
  }
}

class _TagEditorDialog extends StatefulWidget {
  const _TagEditorDialog({required this.track, required this.tags});

  final Track track;
  final TagEdit tags;

  @override
  State<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<_TagEditorDialog> {
  late final _title = TextEditingController(text: widget.tags.title ?? widget.track.title);
  late final _artist = TextEditingController(text: widget.tags.artist ?? '');
  late final _album = TextEditingController(text: widget.tags.album ?? '');
  late final _year = TextEditingController(text: widget.tags.year?.toString() ?? '');
  late final _track = TextEditingController(text: widget.tags.trackNumber?.toString() ?? '');
  late final _disc = TextEditingController(text: widget.tags.discNumber?.toString() ?? '');
  late final _genre = TextEditingController(text: widget.tags.genre ?? '');
  Uint8List? _cover;
  String _coverMime = 'image/jpeg';

  @override
  void dispose() {
    for (final t in [_title, _artist, _album, _year, _track, _disc, _genre]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _pickCover() async {
    final file = (await FilePicker.pickFiles(type: FileType.image, dialogTitle: 'Choose cover art')).firstOrNull;
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      _cover = bytes;
      _coverMime = file.extension?.toLowerCase() == 'png' ? 'image/png' : 'image/jpeg';
    });
  }

  bool _searching = false;

  Future<void> _findCover() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _searching = true);
    try {
      final found = await Metadata.findCoverOnline(_artist.text.trim(), _album.text.trim());
      if (!mounted) return;
      if (found == null) {
        messenger.showSnackBar(const SnackBar(content: Text('No cover found for this album')));
      } else {
        setState(() {
          _cover = found.bytes;
          _coverMime = found.mime;
        });
      }
    } catch (e) {
      debugPrint('Cover search failed: $e');
      messenger.showSnackBar(const SnackBar(content: Text('Couldn\'t reach the Cover Art Archive')));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  String? _text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
  int? _int(TextEditingController c) => int.tryParse(c.text.trim());

  @override
  Widget build(BuildContext context) {
    Widget field(String label, TextEditingController c, {bool number = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        keyboardType: number ? TextInputType.number : null,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      ),
    );
    return AlertDialog(
      title: const Text('Edit info'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox.square(
                      dimension: 72,
                      child: _cover != null
                          // A picked cover can be a 3000 px scan: decode only what the box shows.
                          ? Image.memory(
                              _cover!,
                              key: const ValueKey('new-cover'),
                              fit: BoxFit.cover,
                              cacheWidth: (72 * MediaQuery.devicePixelRatioOf(context)).round(),
                            )
                          : Artwork(track: widget.track, size: 72),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: Metadata.canEditCover(widget.track) ? _pickCover : null,
                              child: const Text('Change cover'),
                            ),
                            ListenableBuilder(
                              listenable: Listenable.merge([_artist, _album]),
                              builder: (context, _) => OutlinedButton(
                                onPressed:
                                    Metadata.canEditCover(widget.track) &&
                                        !_searching &&
                                        _artist.text.trim().isNotEmpty &&
                                        _album.text.trim().isNotEmpty
                                    ? _findCover
                                    : null,
                                child: Text(_searching ? 'Searching…' : 'Find online'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Use a large image (1000 px or more) for sharp artwork.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              field('Title', _title),
              field('Artist', _artist),
              field('Album', _album),
              Row(
                children: [
                  Expanded(child: field('Track', _track, number: true)),
                  const SizedBox(width: 12),
                  Expanded(child: field('Disc', _disc, number: true)),
                  const SizedBox(width: 12),
                  Expanded(child: field('Year', _year, number: true)),
                ],
              ),
              field('Genre', _genre),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final edit = TagEdit(
              title: _text(_title),
              artist: _text(_artist),
              album: _text(_album),
              year: _int(_year),
              trackNumber: _int(_track),
              discNumber: _int(_disc),
              genre: _text(_genre),
            );
            if (_cover != null) {
              edit.cover = _cover;
              edit.coverMime = _coverMime;
            }
            Navigator.pop(context, edit);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
