import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/track.dart';
import '../../services/player_controller.dart';
import '../../services/youtube_music_account.dart';
import '../../services/ytmusic_web.dart' show WebResultKind;
import 'youtube_music_page.dart' show openRemotePlaylist, playlistCover;
import '../shell_scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/shelf.dart';
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
  Future<SearchResults>? _all;

  /// Filter chip: null is "All".
  WebResultKind? _filter;
  Future<List<RemotePlaylist>>? _only;

  /// The last results shown: they stay (dimmed) while the next query loads, instead of flashing a spinner.
  List<Track> _shown = const [];

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
      setState(() => _youtube = _all = _only = null);
      return;
    }
    // Debounced: only hit YouTube once typing pauses.
    _debounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) setState(() => _searchYoutube(q));
    });
  }

  void _submit(String value) {
    // Enter: search now instead of waiting out the debounce.
    _debounce?.cancel();
    if (_controller.text != value) _controller.text = value;
    setState(() => _query = value);
    final q = value.trim();
    if (q.length >= 2) {
      setState(() => _searchYoutube(q));
      RecentSearches.add(q);
    }
  }

  void _searchYoutube(String q) {
    final c = PlayerScope.read(context);
    _youtube = c.searchYoutube(q);
    _all = c.ytMusic.search(q);
    _only = _filter == null || _filter == WebResultKind.song ? null : c.ytMusic.searchOnly(q, _filter!);
  }

  void _setFilter(WebResultKind? f) {
    setState(() {
      _filter = f;
      final q = _query.trim();
      _only = f == null || f == WebResultKind.song || q.length < 2
          ? null
          : PlayerScope.read(context).ytMusic.searchOnly(q, f);
    });
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
    final searching = q.length >= 2;

    return PageScaffold(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (shell.compact) ...[
                  Text('Search', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 16),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: _SearchBox(
                    controller: _controller,
                    focusNode: widget.focusNode,
                    onChanged: _onQuery,
                    onSubmitted: _submit,
                  ),
                ),
                if (searching) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (label, kind) in const [
                        ('All', null),
                        ('Songs', WebResultKind.song),
                        ('Artists', WebResultKind.artist),
                        ('Albums', WebResultKind.album),
                        ('Playlists', WebResultKind.playlist),
                      ])
                        FilterChip(label: Text(label), selected: _filter == kind, onSelected: (_) => _setFilter(kind)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        if (q.isEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
              child: Text(
                'Searches your own music and all of YouTube Music together. Songs with a cloud stream online; '
                'the rest play offline.',
                style: text.bodyLarge?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
          if (artists.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SectionTitle('Browse artists')),
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
          ],
        ] else if (_filter == WebResultKind.song) ...[
          ..._youtubeResults(context),
        ] else if (_filter != null) ...[
          _collectionGrid(context),
        ] else ...[
          if (searching) _topAndSongs(context),
          if (results.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SectionTitle('In your library')),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: shell.compact ? 12 : 16),
              sliver: SliverList.builder(
                itemCount: results.length.clamp(0, 8),
                itemBuilder: (context, i) => TrackRow(
                  track: results[i],
                  onTap: () => c.playList(results, i, from: 'Search'),
                ),
              ),
            ),
          ],
          if (searching) _remoteShelves(context),
          if (artists.isNotEmpty && results.isNotEmpty)
            ..._row(context, 'Your artists', [
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
            ..._row(context, 'Your albums', [
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

  /// "All": the top result card next to the first songs (stacked on phones).
  Widget _topAndSongs(BuildContext context) {
    final c = PlayerScope.read(context);
    final shell = ShellScope.of(context);
    final pad = shell.compact ? 16.0 : 24.0;
    return FutureBuilder<List<Object?>>(
      future: Future.wait<Object?>([
        _all?.then<SearchResults?>((r) => r, onError: (Object _) => null) ?? Future.value(null),
        _youtube?.then<List<Track>?>((r) => r, onError: (Object _) => null) ?? Future.value(null),
      ]),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
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
        final all = snap.data![0] as SearchResults?;
        final songs = (snap.data![1] as List<Track>?) ?? all?.songs ?? const <Track>[];
        final top = all?.top;
        if (top == null && songs.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: pad, vertical: 8),
              child: Text(
                all == null ? 'YouTube search failed. Check your connection.' : 'No YouTube results.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          );
        }
        final topCard = top == null ? null : _TopResult(hit: top);
        final list = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, t) in songs.take(4).indexed)
              _maybeFade(
                i,
                TrackRow(
                  track: t,
                  showAlbum: false,
                  onTap: () => c.playList(songs, i, from: 'YouTube search'),
                ),
              ),
          ],
        );
        Widget heading(String title) => SectionTitle(title);
        return SliverToBoxAdapter(
          child: shell.compact || shell.width < 760
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (topCard != null) ...[
                      heading('Top result'),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: pad),
                        child: topCard,
                      ),
                    ],
                    if (songs.isNotEmpty) ...[
                      heading('Songs'),
                      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: list),
                    ],
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (topCard != null)
                      SizedBox(
                        width: 420,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            heading('Top result'),
                            Padding(
                              padding: EdgeInsets.only(left: pad),
                              child: topCard,
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          heading('Songs'),
                          Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: list),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// "All": rows of artists, albums and playlists from YouTube Music.
  Widget _remoteShelves(BuildContext context) => FutureBuilder<SearchResults>(
    future: _all,
    builder: (context, snap) {
      final r = snap.data;
      if (r == null) return const SliverToBoxAdapter(child: SizedBox.shrink());
      return SliverMainAxisGroup(
        slivers: [
          if (r.artists.isNotEmpty)
            ..._row(context, 'Artists', [for (final a in r.artists) _RemoteCard(collection: a)]),
          if (r.albums.isNotEmpty) ..._row(context, 'Albums', [for (final a in r.albums) _RemoteCard(collection: a)]),
          if (r.playlists.isNotEmpty)
            ..._row(context, 'Playlists', [for (final a in r.playlists) _RemoteCard(collection: a)]),
        ],
      );
    },
  );

  /// A filter chip other than Songs: every matching artist / album / playlist.
  Widget _collectionGrid(BuildContext context) {
    final shell = ShellScope.of(context);
    final pad = shell.compact ? 16.0 : 24.0;
    return FutureBuilder<List<RemotePlaylist>>(
      future: _only,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
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
        final items = snap.data ?? const <RemotePlaylist>[];
        if (items.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: pad, vertical: 8),
              child: Text(
                snap.hasError ? 'YouTube search failed. Check your connection.' : 'Nothing found.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          );
        }
        return SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: shell.compact ? 6 : 14),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: shell.compact ? 180 : 210,
              mainAxisExtent: (shell.compact ? 180 : 210) + 64,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) => _maybeFade(i, _RemoteCard(collection: items[i])),
          ),
        );
      },
    );
  }

  List<Widget> _youtubeResults(BuildContext context) {
    final c = PlayerScope.read(context);
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    return [
      FutureBuilder<List<Track>>(
        future: _youtube,
        builder: (context, snap) {
          final loading = _youtube == null || snap.connectionState != ConnectionState.done;
          if (!loading && snap.hasData) _shown = snap.data!;
          if (loading && _shown.isNotEmpty) {
            final previous = _shown;
            return SliverMainAxisGroup(
              slivers: [
                const SliverToBoxAdapter(child: LinearProgressIndicator(minHeight: 2)),
                SliverOpacity(
                  opacity: 0.5,
                  sliver: SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: shell.compact ? 12 : 16),
                    sliver: SliverList.builder(
                      itemCount: previous.length,
                      itemBuilder: (context, i) => TrackRow(
                        track: previous[i],
                        showAlbum: false,
                        onTap: () => c.playList(previous, i, from: 'YouTube search'),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          if (loading) {
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

/// Opens a search hit: plays a song, opens an artist / album / playlist.
void _openHit(BuildContext context, SearchHit hit) {
  final c = PlayerScope.read(context);
  if (hit.track case final t?) {
    c.playList([t], 0, from: 'Search');
  } else {
    openRemotePlaylist(context, hit.collection!);
  }
}

/// Plays a YouTube Music album / playlist / artist straight from its card.
Future<void> _playRemote(BuildContext context, RemotePlaylist p) async {
  final c = PlayerScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final tracks = await c.ytMusic.collectionTracks(p);
    if (tracks.isNotEmpty) await c.playList(tracks, 0, from: p.title);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Couldn\'t play ${p.title}: $e')));
  }
}

class _RemoteCard extends StatelessWidget {
  const _RemoteCard({required this.collection});

  final RemotePlaylist collection;

  @override
  Widget build(BuildContext context) => MediaCard(
    track: playlistCover(collection),
    title: collection.title,
    subtitle: collection.subtitle ?? '',
    circle: collection.browseId?.startsWith('UC') ?? false,
    online: true,
    onTap: () => openRemotePlaylist(context, collection),
    onPlay: () => _playRemote(context, collection),
  );
}

/// The big "Top result" card.
class _TopResult extends StatelessWidget {
  const _TopResult({required this.hit});

  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final artist = hit.kind == WebResultKind.artist;
    return Material(
      color: AppColors.elevated,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openHit(context, hit),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Artwork(track: hit.cover, size: 96, radius: 6, circle: artist),
                    const SizedBox(height: 16),
                    Text(
                      hit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hit.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              PlayButton(
                playing: false,
                size: 48,
                color: AppColors.accent,
                iconColor: AppColors.onAccent,
                onPressed: () => hit.track != null ? _openHit(context, hit) : _playRemote(context, hit.collection!),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Searches you made, newest first, for the empty search box.
abstract final class RecentSearches {
  static const _key = 'search.recent.v1';
  static const _max = 8;

  static Future<List<String>> load() async => (await SharedPreferences.getInstance()).getStringList(_key) ?? const [];

  static Future<void> add(String query) async {
    final prefs = await SharedPreferences.getInstance();
    final list = [
      query,
      ...(prefs.getStringList(_key) ?? const <String>[]).where((q) => q.toLowerCase() != query.toLowerCase()),
    ];
    await prefs.setStringList(_key, list.take(_max).toList());
  }

  static Future<void> remove(String query) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, [...(prefs.getStringList(_key) ?? const <String>[])..remove(query)]);
  }
}

/// The search field, with a dropdown of suggestions under it while typing
/// (completed searches, then artists / songs / albums to open directly) and
/// recent searches while it's empty. Arrow keys move, Enter picks, Esc closes.
class _SearchBox extends StatefulWidget {
  const _SearchBox({required this.controller, required this.onChanged, required this.onSubmitted, this.focusNode});

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  Timer? _debounce;
  int _request = 0;

  List<String> _recent = const [];
  List<String> _queries = const [];
  List<SearchHit> _hits = const [];

  /// Keyboard highlight across queries, then hits; -1 is none.
  int _highlight = -1;

  /// Closed by Esc / a pick until the next keystroke.
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_sync);
    RecentSearches.load().then((r) {
      if (!mounted) return;
      _recent = r;
      _sync(); // the field may have had focus before these loaded
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.removeListener(_sync);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  String get _text => widget.controller.text.trim();

  int get _count => _text.isEmpty ? _recent.length : _queries.length + _hits.length;

  /// Shows the dropdown when there's something in it and the field has focus.
  void _sync() {
    final show = _focus.hasFocus && !_dismissed && _count > 0;
    if (show != _portal.isShowing) show ? _portal.show() : _portal.hide();
    if (mounted) setState(() {});
  }

  void _changed(String value) {
    widget.onChanged(value);
    _dismissed = false;
    _highlight = -1;
    _debounce?.cancel();
    final q = value.trim();
    if (q.isEmpty) {
      _queries = const [];
      _hits = const [];
      RecentSearches.load().then((r) {
        _recent = r;
        _sync();
      });
      _sync();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      final id = ++_request;
      try {
        final s = await PlayerScope.read(context).ytMusic.suggestions(q);
        if (!mounted || id != _request) return;
        _queries = s.queries.take(6).toList();
        _hits = s.hits.take(5).toList();
      } catch (_) {
        if (id != _request) return;
        _queries = const [];
        _hits = const [];
      }
      _sync();
    });
  }

  void _close() {
    _dismissed = true;
    _highlight = -1;
    _sync();
  }

  void _pickQuery(String q) {
    widget.controller
      ..text = q
      ..selection = TextSelection.collapsed(offset: q.length);
    _close();
    widget.onSubmitted(q);
    RecentSearches.load().then((r) => _recent = r);
  }

  void _pickHit(SearchHit hit) {
    if (_text.isNotEmpty) RecentSearches.add(_text);
    _close();
    _openHit(context, hit);
  }

  void _pick(int i) {
    if (_text.isEmpty) return _pickQuery(_recent[i]);
    if (i < _queries.length) return _pickQuery(_queries[i]);
    _pickHit(_hits[i - _queries.length]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (!_portal.isShowing) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() => _highlight = (_highlight + step).clamp(-1, _count - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter && _highlight >= 0) {
      _pick(_highlight);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, box) => TapRegion(
        groupId: _link,
        onTapOutside: (_) => _close(),
        child: CompositedTransformTarget(
          link: _link,
          child: OverlayPortal(
            controller: _portal,
            overlayChildBuilder: (context) => CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomLeft,
              offset: const Offset(0, 6),
              child: Align(
                alignment: Alignment.topLeft,
                child: TapRegion(
                  groupId: _link,
                  child: SizedBox(width: box.maxWidth, child: _dropdown(context)),
                ),
              ),
            ),
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onKey,
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                onChanged: _changed,
                // Clicking the field again brings the dropdown back after Esc / a pick.
                onTap: () {
                  _dismissed = false;
                  _sync();
                },
                textInputAction: TextInputAction.search,
                onSubmitted: (v) {
                  _close();
                  widget.onSubmitted(v);
                  if (v.trim().isNotEmpty) RecentSearches.load().then((r) => _recent = r);
                },
                style: text.bodyLarge?.copyWith(color: Colors.black, fontWeight: FontWeight.w500),
                cursorColor: Colors.black,
                decoration: InputDecoration(
                  hintText: 'What do you want to play?',
                  hintStyle: text.bodyLarge?.copyWith(color: Colors.black54),
                  prefixIcon: const Icon(Icons.search_rounded, color: Colors.black87),
                  suffixIcon: widget.controller.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          color: Colors.black87,
                          onPressed: () {
                            widget.controller.clear();
                            _changed('');
                            _focus.requestFocus();
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
          ),
        ),
      ),
    );
  }

  Widget _dropdown(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final typed = _text;
    final rows = <Widget>[];
    var i = 0;
    Widget row({
      required Widget leading,
      required Widget title,
      Widget? subtitle,
      Widget? trailing,
      required VoidCallback onTap,
    }) {
      final index = i++;
      return InkWell(
        onTap: onTap,
        child: Container(
          color: index == _highlight ? AppColors.tile : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [title, ?subtitle],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      );
    }

    if (typed.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Text('Recent searches', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
      );
      for (final q in _recent) {
        rows.add(
          row(
            leading: const Icon(Icons.history_rounded, color: AppColors.textSecondary, size: 22),
            title: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyLarge),
            trailing: IconButton(
              tooltip: 'Remove',
              iconSize: 18,
              color: AppColors.textSecondary,
              onPressed: () async {
                await RecentSearches.remove(q);
                _recent = await RecentSearches.load();
                _sync();
              },
              icon: const Icon(Icons.close_rounded),
            ),
            onTap: () => _pickQuery(q),
          ),
        );
      }
    } else {
      for (final q in _queries) {
        // What you typed stays plain; the completion is bold, as in YouTube Music.
        final match = q.toLowerCase().startsWith(typed.toLowerCase());
        rows.add(
          row(
            leading: const Icon(Icons.search_rounded, color: AppColors.textSecondary, size: 22),
            title: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: match ? q.substring(0, typed.length) : ''),
                  TextSpan(
                    text: match ? q.substring(typed.length) : q,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyLarge,
            ),
            onTap: () => _pickQuery(q),
          ),
        );
      }
      if (_queries.isNotEmpty && _hits.isNotEmpty) rows.add(const Divider(height: 9, color: AppColors.hover));
      for (final h in _hits) {
        rows.add(
          row(
            leading: Artwork(track: h.cover, size: 44, radius: 4, circle: h.kind == WebResultKind.artist),
            title: Text(
              h.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              h.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
            onTap: () => _pickHit(h),
          ),
        );
      }
    }
    return Material(
      color: AppColors.elevated,
      elevation: 12,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460),
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 6), shrinkWrap: true, children: rows),
      ),
    );
  }
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
