import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Downloads [url] into [out] over several parallel HTTP range requests.
///
/// One googlevideo connection tops out around 3-6 MB/s and very large ranges
/// get rejected, so the file is split into small chunks that a few workers
/// pull from a shared queue. Each chunk is retried a few times before the
/// whole download fails.
Future<void> rangedDownload({
  required Uri url,
  required File out,
  int? totalBytes,
  int workers = 4,
  int chunkSize = 1 << 20,
  Map<String, String> headers = const {},
  void Function(int received, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final client = http.Client();
  try {
    final total = totalBytes ?? await _probeLength(client, url, headers);
    final raf = await out.open(mode: FileMode.write);
    try {
      await raf.truncate(total);
      var next = 0;
      var received = 0;
      // RandomAccessFile allows one pending operation at a time; chain writes.
      var writes = Future<void>.value();

      Future<void> worker() async {
        while (true) {
          if (isCancelled?.call() ?? false) throw const _Cancelled();
          final start = next;
          if (start >= total) return;
          next += chunkSize;
          final end = (start + chunkSize < total ? start + chunkSize : total) - 1;
          final bytes = await _fetchChunk(client, url, headers, start, end);
          writes = writes.then((_) async {
            await raf.setPosition(start);
            await raf.writeFrom(bytes);
          });
          received += bytes.length;
          onProgress?.call(received, total);
        }
      }

      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
      await writes;
    } finally {
      await raf.close();
    }
  } on _Cancelled {
    throw const DownloadCancelled();
  } finally {
    client.close();
  }
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

class _Cancelled implements Exception {
  const _Cancelled();
}

Future<List<int>> _fetchChunk(http.Client client, Uri url, Map<String, String> headers, int start, int end) async {
  Object? lastError;
  for (var attempt = 0; attempt < 4; attempt++) {
    try {
      final req = http.Request('GET', url)
        ..headers.addAll(headers)
        ..headers['Range'] = 'bytes=$start-$end';
      final res = await client.send(req).timeout(const Duration(seconds: 20));
      if (res.statusCode != 206 && res.statusCode != 200) {
        throw http.ClientException('HTTP ${res.statusCode}', url);
      }
      final body = await res.stream.toBytes().timeout(const Duration(seconds: 60));
      if (body.length != end - start + 1) throw http.ClientException('Short read', url);
      return body;
    } catch (e) {
      lastError = e;
      await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
    }
  }
  throw lastError!;
}

Future<int> _probeLength(http.Client client, Uri url, Map<String, String> headers) async {
  final req = http.Request('GET', url)
    ..headers.addAll(headers)
    ..headers['Range'] = 'bytes=0-0';
  final res = await client.send(req);
  await res.stream.drain<void>();
  final range = res.headers['content-range']; // "bytes 0-0/12345"
  final total = int.tryParse(range?.split('/').last ?? '');
  if (total == null) throw http.ClientException('Server did not report a length', url);
  return total;
}
