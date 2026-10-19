import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../services/player_controller.dart';
import '../theme.dart';

/// One-time Google sign-in in the app's own WebView. When the login lands back
/// on music.youtube.com, the session (cookies plus visitor data) is read out of
/// the page and handed to YoutubeMusicAccount.connectWebSession.
class YoutubeMusicLoginPage extends StatefulWidget {
  const YoutubeMusicLoginPage({super.key});

  @override
  State<YoutubeMusicLoginPage> createState() => _YoutubeMusicLoginPageState();
}

class _YoutubeMusicLoginPageState extends State<YoutubeMusicLoginPage> {
  static final _startUrl = WebUri(
    'https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com%2F',
  );

  static const _origin = 'https://music.youtube.com';

  /// Values YouTube Music keeps on every signed-in page.
  static const _sessionJs = '''
JSON.stringify((() => {
  const c = (window.yt && window.yt.config_) || null;
  if (!c) return null;
  return { visitorData: c.VISITOR_DATA || '', sessionIndex: c.SESSION_INDEX ?? 0 };
})())
''';

  InAppWebViewController? _web;
  WebUri? _lastUrl;
  bool _loading = true;
  bool _checking = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Sign in to YouTube Music', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        Text(
                          _checking ? 'Checking the session…' : 'Google handles the sign-in. OpenMusic only keeps the session.',
                          style: text.bodySmall?.copyWith(color: AppColors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (_checking)
                    const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2, backgroundColor: AppColors.panel),
          if (_error != null)
            Container(
              width: double.infinity,
              color: AppColors.elevated,
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_error!, style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
                  ),
                  TextButton(
                    onPressed: _checking ? null : () => _capture(_lastUrl),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: _startUrl),
              initialSettings: InAppWebViewSettings(javaScriptEnabled: true, domStorageEnabled: true),
              onWebViewCreated: (controller) => _web = controller,
              onLoadStart: (controller, url) => setState(() => _loading = true),
              onLoadStop: (controller, url) {
                setState(() => _loading = false);
                _lastUrl = url;
                _capture(url);
              },
              onReceivedError: (controller, request, error) {
                if (request.isForMainFrame != true) return;
                setState(() => _error = error.description);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Runs on every page that lands on music.youtube.com. Cookies can settle a
  /// moment after the page does, so a missing session is retried briefly before
  /// the error hints at signing in first.
  Future<void> _capture(WebUri? url) async {
    if (_checking) return;
    if (url?.host != 'music.youtube.com') return;
    final account = PlayerScope.read(context).ytMusic;
    _checking = true;
    setState(() => _error = null);
    try {
      for (var attempt = 0; attempt < 15; attempt++) {
        final session = await _readSession();
        if (session != null) {
          final ok = await account.connectWebSession(
            cookies: session.cookies,
            visitorData: session.visitorData,
            authUser: session.authUser,
          );
          if (!mounted) return;
          if (ok) {
            Navigator.of(context).maybePop();
          } else {
            setState(() => _error = account.error ?? 'Could not use that sign-in.');
          }
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (mounted) {
        setState(() => _error = 'No signed-in session on this page yet. Finish signing in above, then tap Try again.');
      }
    } finally {
      _checking = false;
      if (mounted) setState(() {});
    }
  }

  Future<({String cookies, String visitorData, String authUser})?> _readSession() async {
    final web = _web;
    if (web == null) return null;
    final jar = await CookieManager.instance().getCookies(url: WebUri(_origin));
    final header = jar.map((c) => '${c.name}=${c.value}').join('; ');
    if (!header.contains('PAPISID=') && !header.contains('SAPISID=')) return null;
    final raw = await web.evaluateJavascript(source: _sessionJs);
    if (raw is! String || raw.isEmpty || raw == 'null') return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final visitor = decoded['visitorData'] as String? ?? '';
    if (visitor.isEmpty) return null;
    final index = '${decoded['sessionIndex'] ?? ''}';
    return (cookies: header, visitorData: visitor, authUser: index.isEmpty ? '0' : index);
  }
}
