import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' show Video;

import '../services/player_controller.dart';
import '../services/youtube_importer.dart';
import 'theme.dart';
import 'widgets/controls.dart';

/// Opens the "paste a YouTube link" flow: bottom sheet on phones, dialog elsewhere.
/// Resolves to true when something was queued.
Future<bool> showYoutubeImport(BuildContext context, {required bool compact, String? initialUrl}) async {
  final controller = PlayerScope.read(context);
  final body = PlayerScope(
    controller: controller,
    child: _ImportForm(initialUrl: initialUrl),
  );
  final queued = compact
      ? await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: AppColors.elevated,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
          builder: (context) => Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
            child: body,
          ),
        )
      : await showDialog<bool>(
          context: context,
          builder: (context) => Dialog(
            backgroundColor: AppColors.elevated,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: body),
          ),
        );
  return queued ?? false;
}

class _ImportForm extends StatefulWidget {
  const _ImportForm({this.initialUrl});

  final String? initialUrl;

  @override
  State<_ImportForm> createState() => _ImportFormState();
}

class _ImportFormState extends State<_ImportForm> {
  final _url = TextEditingController();
  YoutubePreview? _preview;
  String? _error;
  bool _loading = false;
  int _lookup = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialUrl != null) {
      _url.text = widget.initialUrl!;
      _resolve();
    } else {
      _pasteIfYoutube();
    }
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  /// Saves a step: if the clipboard already holds a YouTube link, use it.
  Future<void> _pasteIfYoutube() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (!mounted || text == null || _url.text.isNotEmpty || !YoutubeImporter.looksLikeYoutubeUrl(text)) return;
    _url.text = text;
    _resolve();
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text == null || text.isEmpty) return;
    _url.text = text;
    _resolve();
  }

  Future<void> _resolve() async {
    final text = _url.text.trim();
    final lookup = ++_lookup;
    if (text.isEmpty) {
      setState(() => _preview = _error = null);
      return;
    }
    if (!YoutubeImporter.looksLikeYoutubeUrl(text)) {
      setState(() {
        _preview = null;
        _error = 'Paste a youtube.com or youtu.be link to a video or playlist.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await PlayerScope.read(context).youtube.resolve(text);
      if (!mounted || lookup != _lookup) return;
      setState(() => _preview = preview);
    } catch (e) {
      if (!mounted || lookup != _lookup) return;
      setState(() {
        _preview = null;
        _error = 'Couldn\'t load that link. It may be private, removed or region-locked.';
      });
    } finally {
      if (mounted && lookup == _lookup) setState(() => _loading = false);
    }
  }

  void _download() {
    final videos = switch (_preview) {
      VideoPreview(:final video) => [video],
      PlaylistPreview(:final videos) => videos,
      null => <Video>[],
    };
    final queued = PlayerScope.read(context).youtube.enqueue(videos);
    Navigator.of(context).pop(queued > 0);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final preview = _preview;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Import from YouTube', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'Downloads the audio track and adds it to your library.',
            style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _url,
            autofocus: widget.initialUrl == null,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _resolve(),
            onChanged: (v) {
              if (YoutubeImporter.looksLikeYoutubeUrl(v)) _resolve();
            },
            decoration: InputDecoration(
              hintText: 'https://youtube.com/watch?v=…',
              filled: true,
              fillColor: AppColors.hover,
              prefixIcon: const Icon(Icons.link_rounded),
              suffixIcon: TextButton(onPressed: _paste, child: const Text('Paste')),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 16),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
                  )
                : _error != null
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!, style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
                  )
                : preview == null
                ? const SizedBox(width: double.infinity)
                : _PreviewCard(preview: preview),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Saved in the best quality YouTube offers (up to ~160 kbps Opus/AAC), without re-encoding.',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
              const SizedBox(width: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.textPrimary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                  textStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                onPressed: preview == null || _loading ? null : _download,
                child: Text(switch (preview) {
                  PlaylistPreview(:final videos) => 'Download ${videos.length}',
                  _ => 'Download',
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewCard extends StatefulWidget {
  const _PreviewCard({required this.preview});

  final YoutubePreview preview;

  @override
  State<_PreviewCard> createState() => _PreviewCardState();
}

class _PreviewCardState extends State<_PreviewCard> {
  late final Future<String?> _sizeLine = _loadSizeLine();

  /// Exact size for one video (yt-dlp resolves it, which also primes the
  /// download); a duration-based estimate for playlists.
  Future<String?> _loadSizeLine() async {
    switch (widget.preview) {
      case VideoPreview(:final video):
        final peek = await PlayerScope.read(context).youtube.peekAudio(video.id.value);
        if (peek == null) return null;
        return [peek.quality, if (peek.size != null) formatBytes(peek.size!)].join(' • ');
      case PlaylistPreview(:final videos):
        final seconds = videos.fold(0, (sum, v) => sum + (v.duration?.inSeconds ?? 0));
        if (seconds == 0) return null;
        // ~130 kbps Opus/AAC is what YouTube serves for most music.
        return 'About ${formatBytes(seconds * 130000 / 8)} total';
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final text = Theme.of(context).textTheme;
    final (thumb, title, subtitle) = switch (preview) {
      VideoPreview(:final video) => (
        video.thumbnails.mediumResUrl,
        video.title,
        [video.author, if (video.duration != null) formatDuration(video.duration)].join(' • '),
      ),
      PlaylistPreview(:final playlist, :final videos) => (
        videos.firstOrNull?.thumbnails.mediumResUrl,
        playlist.title,
        'Playlist • ${playlist.author} • ${videos.length} videos',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.hover, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 112,
              height: 63,
              child: thumb == null
                  ? const ColoredBox(color: AppColors.elevated)
                  : Image.network(
                      thumb,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(color: AppColors.elevated),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                ),
                FutureBuilder<String?>(
                  future: _sizeLine,
                  builder: (context, snap) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      snap.connectionState == ConnectionState.done ? (snap.data ?? '') : 'Checking size…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
