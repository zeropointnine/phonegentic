import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:puppeteer/puppeteer.dart';

class ChromeBrowserService {
  static final _log = Logger();

  Browser? _browser;
  int _debugPort = 9222;
  String? _userDataDir;

  bool get isRunning => _browser != null;
  int get debugPort => _debugPort;

  void configure({int? debugPort, String? userDataDir}) {
    if (debugPort != null) _debugPort = debugPort;
    _userDataDir = userDataDir;
  }

  String get launchCommand {
    final buf = StringBuffer(
      '/Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome '
      '--remote-debugging-port=$_debugPort ',
    );
    if (_userDataDir != null && _userDataDir!.isNotEmpty) {
      buf.write('--user-data-dir=$_userDataDir ');
    }
    buf.write('--no-first-run --no-default-browser-check');
    return buf.toString();
  }

  Future<bool> isDebugPortOpen() async {
    try {
      final resp = await http
          .get(Uri.parse('http://127.0.0.1:$_debugPort/json/version'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Browser> ensureBrowser() async {
    if (_browser != null) return _browser!;

    if (!await isDebugPortOpen()) {
      throw Exception(
        'No Chrome found on port $_debugPort.\n'
        'Start Chrome with remote debugging first.',
      );
    }

    try {
      _browser = await puppeteer.connect(
        browserUrl: 'http://127.0.0.1:$_debugPort',
      );
      _log.i('Connected to Chrome on port $_debugPort');
      return _browser!;
    } catch (e) {
      _log.e('CDP connect failed', error: e);
      rethrow;
    }
  }

  /// Navigate to [url], wait for DOM + a JS render delay, then evaluate
  /// [jsExpression]. If the navigation times out waiting for
  /// domContentLoaded (common with heavy SPAs like Gmail), we still
  /// proceed with the JS evaluation since the page content is typically
  /// available before that event formally fires.
  Future<T> navigateAndEvaluate<T>(
    String url,
    String jsExpression, {
    Duration timeout = const Duration(seconds: 20),
    Duration renderDelay = const Duration(seconds: 6),
  }) async {
    final browser = await ensureBrowser();
    final page = await browser.newPage();
    try {
      try {
        await page.goto(url, wait: Until.domContentLoaded, timeout: timeout);
      } on TimeoutException {
        _log.w('Navigation timed out for $url — proceeding with evaluation');
      }
      await Future<void>.delayed(renderDelay);
      final result = await page.evaluate<T>(jsExpression);
      return result;
    } finally {
      await page.close();
    }
  }

  Future<void> close() async {
    if (_browser != null) {
      try {
        await _browser!.close();
      } catch (_) {}
      _browser = null;
      _log.i('Chrome disconnected');
    }
  }

  void dispose() {
    close();
  }
}
