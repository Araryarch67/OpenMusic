import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/track.dart';

import '../../services/player_controller.dart';
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/shelf.dart';
import '../widgets/source_switch.dart';
import '../widgets/track_row.dart';
import '../widgets/smooth_scroll.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.focusNode});

  final FocusNode? focusNode;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  String _query = '';
  Timer? _debounce;
  Future<List<Track>>? _youtube;
  String? _youtubeQuery;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQuery(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    final q = value.trim();
    if (q.length < 2) {
      setState(() => _youtube = null);
      return;
    }
    // Debounced: only hit YouTube once typing pauses.
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted && PlayerScope.read(context).source == MusicSource.youtubeMusic) {
        setState(() => _searchYoutube(q));
      }
    });
  }

  void _searchYoutube(String q) {
    _youtubeQuery = q;
    _youtube = PlayerScope.read(context).searchYoutube(q);
  }

  @override
  Widget build(BuildContext context) {
    final c = PlayerScope.of(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    final results = c.search(_query);
    final q = _query.trim().toLowerCase();
    final artists = q.isEmpty ? c.artists : c.artists.where((a) => a.title.toLowerCase().contains(q)).toList();
    final albums = q.isEmpty ? const [] : c.albums.where((a) => a.title.toLowerCase().contains(q)).toList();
    final onYoutube = c.source == MusicSource.youtubeMusic;
    // Switching source with a query already typed: search right away.
    if (onYoutube && q.length >= 2 && _youtubeQuery != _query.trim() && !(_debounce?.isActive ?? false)) {
      _searchYoutube(_query.trim());
    }

    return PageScaffold(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (shell.compact) ...[
                  const SourceSwitch(),
                  const SizedBox(height: 16),
                  Text('Search', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 16),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: TextField(
                    controller: _controller,
                    focusNode: widget.focusNode,
                    onChanged: _onQuery,
                    style: text.bodyLarge?.copyWith(color: Colors.black, fontWeight: FontWeight.w500),
                    cursorColor: Colors.black,
                    decoration: InputDecoration(
                      hintText: onYoutube ? 'Search YouTube Music' : 'Search your library',
                      hintStyle: text.bodyLarge?.copyWith(color: Colors.black54),
                      prefixIcon: const Icon(Icons.search_rounded, color: Colors.black87),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear',
                              color: Colors.black87,
                              onPressed: () {
                                _controller.clear();
                                _onQuery('');
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(500), borderSide: BorderSide.none),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (onYoutube) ...[
          if (q.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
                child: Text(
                  'Find any song on YouTube Music. It plays straight away, and you can download it for offline.',
                  style: text.bodyLarge?.copyWith(color: AppColors.textSecondary),
                ),
              ),
            )
          else
            ..._youtubeResults(context),
        ] else if (q.isEmpty) ...[
          SliverToBoxAdapter(child: SectionTitle(artists.isEmpty ? 'Nothing to browse yet' : 'Browse artists')),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                childAspectRatio: 1.6,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
              ),
              itemCount: artists.length,
              itemBuilder: (context, i) => AccentBuilder(
                track: artists[i].cover,
                builder: (context, color) => _BrowseTile(
                  title: artists[i].title,
                  color: color,
                  cover: Artwork(track: artists[i].cover, radius: 4),
                  onTap: () => shell.openCollection(artists[i]),
                ),
              ),
            ),
          ),
        ] else if (results.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
              child: Text(
                'Nothing in your library matches "${_query.trim()}".',
                style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          )
        else ...[
          const SliverToBoxAdapter(child: SectionTitle('Songs')),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: shell.compact ? 12 : 16),
            sliver: SliverList.builder(
              itemCount: results.length.clamp(0, 50),
              itemBuilder: (context, i) => TrackRow(
                track: results[i],
                onTap: () => c.playList(results, i, from: 'Search'),
              ),
            ),
          ),
          if (artists.isNotEmpty)
            ..._row(context, 'Artists', [
              for (final a in artists)
                MediaCard(
                  track: a.cover,
                  title: a.title,
                  subtitle: 'Artist',
                  circle: true,
                  onTap: () => shell.openCollection(a),
                ),
            ]),
          if (albums.isNotEmpty)
            ..._row(context, 'Albums', [
              for (final a in albums)
                MediaCard(
                  track: a.cover,
                  title: a.title,
                  subtitle: a.subtitle,
                  onTap: () => shell.openCollection(a),
                  onPlay: () => c.playCollection(a),
                ),
            ]),
        ],
      ],
    );
  }

  List<Widget> _youtubeResults(BuildContext context) {
    final c = PlayerScope.read(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    return [
      const SliverToBoxAdapter(child: SectionTitle('Songs')),
      FutureBuilder<List<Track>>(
        future: _youtube,
        builder: (context, snap) {
          if (_youtube == null || snap.connectionState != ConnectionState.done) {
            return SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: pad, vertical: 16),
                child: const Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
            );
          }
          final tracks = snap.data ?? const <Track>[];
          if (snap.hasError || tracks.isEmpty) {
            return SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: pad, vertical: 8),
                child: Text(
                  snap.hasError ? 'YouTube search failed. Check your connection.' : 'No YouTube results.',
                  style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                ),
              ),
            );
          }
          return SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: shell.compact ? 12 : 16),
            sliver: SliverList.builder(
              itemCount: tracks.length,
              // Results arriving from the network fade in, top first.
              itemBuilder: (context, i) => _maybeFade(
                i,
                TrackRow(
                  track: tracks[i],
                  showAlbum: false,
                  onTap: () => c.playList(tracks, i, from: 'YouTube search'),
                ),
              ),
            ),
          );
        },
      ),
    ];
  }

  List<Widget> _row(BuildContext context, String title, List<Widget> cards) => [
    SliverToBoxAdapter(
      child: Shelf(title: title, cards: cards),
    ),
  ];
}

/// Coloured "genre"-style tile with a tilted cover peeking out of the corner.
class _BrowseTile extends StatelessWidget {
  const _BrowseTile({required this.title, required this.color, required this.cover, required this.onTap});

  final String title;
  final Color color;
  final Widget cover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Positioned(
              right: -14,
              bottom: -6,
              width: 76,
              height: 76,
              child: Transform.rotate(
                angle: 0.44,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 4))],
                  ),
                  child: cover,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _maybeFade(int i, Widget child) => i < 12
    ? FadeIn(
        delay: Duration(milliseconds: 30 * i),
        offset: 8,
        child: child,
      )
    : child;
