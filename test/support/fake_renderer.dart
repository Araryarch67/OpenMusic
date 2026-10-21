// A DLNA media renderer for tests (unit and integration).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:openmusic/services/dlna.dart';
import 'package:xml/xml.dart';

const fakeDescription = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
    <friendlyName>Root of a TV</friendlyName>
    <UDN>uuid:root</UDN>
    <deviceList>
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>Living Room TV</friendlyName>
        <UDN>uuid:tv-1</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
            <controlURL>/rc</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>av/control</controlURL>
          </service>
        </serviceList>
      </device>
    </deviceList>
  </device>
</root>''';

/// A renderer in a test: answers the control requests a real one does and,
/// like a real one, downloads what it is told to play (in byte ranges).
class FakeRenderer {
  late final HttpServer _server;
  final actions = <String>[];
  final args = <String, Map<String, String>>{};
  String state = 'NO_MEDIA_PRESENT';
  Duration position = Duration.zero;
  Duration? trackDuration;
  int volume = 30;
  Uint8List? fetched;
  String? fetchedType;
  bool down = false;

  /// Wrong answers from the cast server (tests expect none).
  final problems = <String>[];

  /// Fetches made by the renderer, as "Range" header values.
  final ranges = <String?>[];

  Uri get location => Uri.parse('http://127.0.0.1:${_server.port}/desc.xml');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  RawDatagramSocket? _ssdp;

  /// Answers SSDP searches like a TV on the network; false where the SSDP
  /// port can't be shared.
  Future<bool> answerSearches() async {
    try {
      final s = _ssdp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        1900,
        reuseAddress: true,
        reusePort: true,
      );
      s.joinMulticast(InternetAddress('239.255.255.250'));
      s.listen((event) {
        final d = s.receive();
        if (d == null || !utf8.decode(d.data, allowMalformed: true).startsWith('M-SEARCH')) return;
        s.send(
          utf8.encode(
            'HTTP/1.1 200 OK\r\nLOCATION: $location\r\n'
            'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:tv-1\r\n\r\n',
          ),
          d.address,
          d.port,
        );
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() async {
    _ssdp?.close();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (down) {
      res.statusCode = 503;
      return res.close();
    }
    if (req.uri.path == '/desc.xml') {
      res.write(fakeDescription);
      return res.close();
    }
    final body = await utf8.decodeStream(req);
    final action = req.headers.value('SOAPACTION')!.replaceAll('"', '').split('#').last;
    final call = XmlDocument.parse(body).descendants.whereType<XmlElement>().firstWhere((e) => e.localName == action);
    final a = {for (final e in call.childElements) e.localName: e.innerText};
    actions.add(action);
    args[action] = a;
    final reply = <String, String>{};
    switch (action) {
      case 'SetAVTransportURI':
        state = 'STOPPED';
        position = Duration.zero;
        await _fetch(Uri.parse(a['CurrentURI']!));
      case 'Play':
        state = 'PLAYING';
      case 'Pause':
        state = 'PAUSED_PLAYBACK';
      case 'Stop':
        state = 'STOPPED';
      case 'Seek':
        position = Dlna.parseTime(a['Target'])!;
      case 'GetTransportInfo':
        reply['CurrentTransportState'] = state;
      case 'GetPositionInfo':
        reply['RelTime'] = Dlna.formatTime(position);
        reply['TrackDuration'] = trackDuration == null ? 'NOT_IMPLEMENTED' : Dlna.formatTime(trackDuration!);
      case 'GetVolume':
        reply['CurrentVolume'] = '$volume';
      case 'SetVolume':
        volume = int.parse(a['DesiredVolume']!);
    }
    res.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    res.write(
      '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
      '<u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
      '${reply.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join()}'
      '</u:${action}Response></s:Body></s:Envelope>',
    );
    await res.close();
  }

  /// Reads the media in 64 KB ranges until the end, as players do.
  Future<void> _fetch(Uri url) async {
    final client = http.Client();
    try {
      final head = await client.head(url);
      fetchedType = head.headers['content-type'];
      final seekable = head.headers['accept-ranges'] == 'bytes';
      if (!seekable) {
        ranges.add(null);
        fetched = (await client.get(url)).bodyBytes;
        return;
      }
      final total = int.parse(head.headers['content-length']!);
      final out = BytesBuilder();
      for (var at = 0; at < total; at += 65536) {
        final range = 'bytes=$at-${math.min(at + 65535, total - 1)}';
        ranges.add(range);
        final r = await client.get(url, headers: {'Range': range});
        final want = '${range.replaceFirst('=', ' ')}/$total';
        if (r.statusCode != 206 || r.headers['content-range'] != want) {
          problems.add('$range: HTTP ${r.statusCode}, Content-Range ${r.headers['content-range']}');
        }
        out.add(r.bodyBytes);
      }
      fetched = out.takeBytes();
    } finally {
      client.close();
    }
  }
}
