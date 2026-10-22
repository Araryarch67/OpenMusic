import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/playlist_transfer.dart';
import 'package:openmusic/ui/playlist_import.dart';

const link = 'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M';

Track yt(String id, String title, String artist) =>
    Track.youtube(videoId: id, title: title, artist: artist, duration: const Duration(seconds: 200));

ForeignSong song(String title, String artist) =>
    ForeignSong(title: title, artist: artist, duration: const Duration(seconds: 200));

/// Shows the dialog from a button and keeps what it returns.
Future<List<ImportedPlaylist?>> open(
  WidgetTester t, {
  required Future<ForeignPlaylist> Function(String) read,
  Future<List<Track>> Function(String)? search,
  required List<(String, List<Track>)> saves,
}) async {
  final results = <ImportedPlaylist?>[];
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await showDialog<ImportedPlaylist>(
                context: context,
                builder: (_) => PlaylistImportDialog(
                  initial: link,
                  signedIn: true,
                  read: read,
                  search: search ?? (q) async => q.startsWith('Gone') ? [] : [yt(q, q.split(' ').first, 'A')],
                  videos: (_) async => [],
                  save: (title, tracks) async {
                    saves.add((title, tracks));
                    return (title: title, youtubeId: 'PLnew', local: null);
                  },
                ),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
  return results;
}

void main() {
  testWidgets('imports, says what was left out, opens the playlist', (t) async {
    final saves = <(String, List<Track>)>[];
    final results = await open(
      t,
      read: (_) async => ForeignPlaylist(
        title: 'Road trip',
        service: 'Spotify',
        songs: [song('One', 'A'), song('Two', 'A'), song('Gone', 'A')],
        total: 5,
      ),
      saves: saves,
    );
    expect(find.text('Import a playlist'), findsOneWidget);
    await t.tap(find.text('Import'));
    await t.pumpAndSettle();

    expect(saves.single.$1, 'Road trip');
    expect(saves.single.$2.map((t) => t.title), ['One', 'Two']);
    expect(find.text('Imported "Road trip"'), findsOneWidget);
    expect(find.text('2 of 5 songs added to your YouTube Music library.'), findsOneWidget);
    expect(find.textContaining('only shows the first 3 songs'), findsOneWidget);
    expect(find.text('1 song isn\'t on YouTube Music:'), findsOneWidget);
    expect(find.text('A - Gone'), findsOneWidget);

    await t.tap(find.text('Open playlist'));
    await t.pumpAndSettle();
    expect(results.single?.youtubeId, 'PLnew');
  });

  testWidgets('a link that can\'t be read stays open with the reason', (t) async {
    final saves = <(String, List<Track>)>[];
    await open(
      t,
      read: (_) async => throw const PlaylistTransferError('That playlist is empty, or it\'s private.'),
      saves: saves,
    );
    await t.tap(find.text('Import'));
    await t.pumpAndSettle();
    expect(find.text('That playlist is empty, or it\'s private.'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
    expect(saves, isEmpty);
  });

  testWidgets('cancelling stops the import; trying again saves once', (t) async {
    final saves = <(String, List<Track>)>[];
    final slow = Completer<void>();
    var calls = 0;
    await open(
      t,
      read: (_) async => ForeignPlaylist(title: 'Road trip', service: 'Spotify', songs: [song('One', 'A')]),
      // The first lookup hangs until after Cancel; later ones answer at once.
      search: (q) async {
        if (calls++ == 0) await slow.future;
        return [yt('one', 'One', 'A')];
      },
      saves: saves,
    );
    await t.tap(find.text('Import'));
    await t.pump();
    await t.pump();
    expect(find.textContaining('Finding songs in YouTube Music'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    await t.tap(find.text('Import'));
    await t.pumpAndSettle();
    slow.complete();
    await t.pumpAndSettle();
    expect(saves, hasLength(1));
    expect(find.text('Imported "Road trip"'), findsOneWidget);
  });
}
