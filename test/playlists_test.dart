import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/models/track.dart';
import 'package:openmusic/services/player_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _yt(String id) => Track.youtube(videoId: id, title: 'Song $id', artist: 'Artist');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Downloaded tracks are relocated under the app's documents dir on load.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (_) async => Directory.systemTemp.path,
  );

  test('OpenMusic playlists mix local and YouTube songs, and persist', () async {
    final local = Track.fromUri(Uri.file('/music/Band - Local Song.flac'));
    SharedPreferences.setMockInitialValues({
      'library.v1': jsonEncode([local.toJson()]),
    });
    final c = PlayerController();
    await c.load();

    final p = c.createPlaylist('Mix', tracks: [local, _yt('a')]);
    expect(c.playlists.single.name, 'Mix');
    expect(c.addToPlaylist(p.id, [_yt('a'), _yt('b')]), 1, reason: 'duplicates are skipped');
    c.movePlaylistItem(p.id, 2, 0);
    expect(c.playlists.single.tracks.map((t) => t.title), ['Song b', 'Local Song', 'Song a']);
    c.removeFromPlaylist(p.id, local);
    c.renamePlaylist(p.id, 'Road trip');
    final col = c.playlistById(p.id)!;
    expect(col.kind, CollectionKind.playlist);
    expect(col.title, 'Road trip');
    expect(col.tracks, hasLength(2));

    await Future<void>.delayed(Duration.zero);
    final again = PlayerController();
    await again.load();
    expect(again.playlists.single.name, 'Road trip');
    expect(again.playlists.single.tracks.map((t) => t.videoId), ['b', 'a']);

    again.deletePlaylist(p.id);
    expect(again.playlists, isEmpty);
  });

  test('a downloaded YouTube song plays from the file', () async {
    final downloaded = Track(
      id: 'file:///music/song.m4a',
      uri: Uri.file('/music/song.m4a'),
      title: 'Song x',
      artist: 'Artist',
      sourceUrl: 'https://www.youtube.com/watch?v=x',
    );
    SharedPreferences.setMockInitialValues({
      'library.v1': jsonEncode([downloaded.toJson()]),
    });
    final c = PlayerController();
    await c.load();
    expect(c.downloadedCopy(_yt('x'))?.id, downloaded.id);
    expect(c.isOffline(_yt('x')), isTrue);
    expect(c.isOffline(_yt('y')), isFalse);
  });
}
