import 'package:flutter_test/flutter_test.dart';
import 'package:openmusic/services/youtube_importer.dart';

void main() {
  group('parseTitle', () {
    test('splits "Artist - Song" and strips video noise', () {
      final r = YoutubeImporter.parseTitle('Daft Punk - Get Lucky (Official Music Video)', 'DaftPunkVEVO');
      expect(r.artist, 'Daft Punk');
      expect(r.title, 'Get Lucky');
    });

    test('strips bracketed lyric/audio tags and pipe suffixes', () {
      final r = YoutubeImporter.parseTitle('Hozier – Too Sweet [Lyrics] | Best of 2024', 'Some Channel');
      expect(r.artist, 'Hozier');
      expect(r.title, 'Too Sweet');
    });

    test('falls back to the channel name, without " - Topic"', () {
      final r = YoutubeImporter.parseTitle('Blinding Lights (Audio)', 'The Weeknd - Topic');
      expect(r.artist, 'The Weeknd');
      expect(r.title, 'Blinding Lights');
    });

    test('handles "Song - Artist" order when the channel is the artist', () {
      final r = YoutubeImporter.parseTitle('BELLAKEO (Video Oficial) - Peso Pluma, Anitta', 'Peso Pluma');
      expect(r.title, 'BELLAKEO');
      expect(r.artist, 'Peso Pluma, Anitta');
    });

    test('keeps meaningful parentheses', () {
      final r = YoutubeImporter.parseTitle('Artist - Song (Live at Wembley)', 'x');
      expect(r.title, 'Song (Live at Wembley)');
    });
  });

  test('recognises video and playlist links', () {
    expect(YoutubeImporter.looksLikeYoutubeUrl('https://youtu.be/jNQXAC9IVRw'), isTrue);
    expect(YoutubeImporter.looksLikeYoutubeUrl('https://www.youtube.com/watch?v=jNQXAC9IVRw&t=3s'), isTrue);
    expect(YoutubeImporter.looksLikeYoutubeUrl('https://music.youtube.com/watch?v=jNQXAC9IVRw'), isTrue);
    expect(
      YoutubeImporter.looksLikeYoutubeUrl('https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI'),
      isTrue,
    );
    expect(YoutubeImporter.looksLikeYoutubeUrl('https://example.com/song.mp3'), isFalse);
  });
}
