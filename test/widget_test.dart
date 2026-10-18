import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/models/track.dart';

void main() {
  test('parses artist and title from filename', () {
    final t = Track.fromUri(Uri.file('/music/Daft Punk - One More Time.mp3'));
    expect(t.artist, 'Daft Punk');
    expect(t.title, 'One More Time');
  });

  test('falls back to unknown artist', () {
    final t = Track.fromUri(Uri.file('/music/some_song.flac'));
    expect(t.artist, 'Unknown artist');
    expect(t.title, 'some song');
  });

  test('handles percent signs and unicode in filenames', () {
    final t = Track.fromUri(Uri.file('/music/Kōji - 100% Love.mp3'));
    expect(t.artist, 'Kōji');
    expect(t.title, '100% Love');
  });

  test('recognises audio extensions', () {
    expect(Track.isAudioPath('/a/b.FLAC'), isTrue);
    expect(Track.isAudioPath('/a/b.txt'), isFalse);
  });
}
