import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:puppeteer/puppeteer.dart';

import 'chrome_browser_service.dart';
import 'gmail_config.dart';
import 'gmail_models.dart';

class GmailService extends ChangeNotifier {
  static final _log = Logger();

  final ChromeBrowserService _chrome = ChromeBrowserService();
  ChromeBrowserService get chrome => _chrome;

  GmailConfig _config = const GmailConfig();
  GmailConfig get config => _config;

  EmailSearchResult? _lastSearch;
  EmailSearchResult? get lastSearch => _lastSearch;

  EmailInfo? _lastRead;
  EmailInfo? get lastRead => _lastRead;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  bool? _connected;
  bool? get connected => _connected;

  // ── JS: scrape Gmail search results page ─────────────────────────────

  static const _searchJs = r'''
() => {
  const rows = document.querySelectorAll('tr.zA');
  const emails = [];
  for (const row of rows) {
    const sender = (row.querySelector('.yW span') || {}).getAttribute?.('email')
                || (row.querySelector('.yW span') || {}).textContent?.trim()
                || '';
    const subject = (row.querySelector('.bog') || {}).textContent?.trim() || '';
    const snippet = (row.querySelector('.y2') || {}).textContent?.trim() || '';
    const date = (row.querySelector('.xW.xY span') || {}).getAttribute?.('title')
              || (row.querySelector('.xW.xY span') || {}).textContent?.trim()
              || '';
    const isUnread = row.classList.contains('zE');
    emails.push({ sender, subject, snippet, date, isUnread, recipient: '', body: '' });
  }
  return emails;
}
''';

  // ── JS: scrape an open email's full content ──────────────────────────

  static const _readJs = r'''
() => {
  const subjectEl = document.querySelector('h2.hP');
  const subject = subjectEl ? subjectEl.textContent.trim() : '';

  const senderEl = document.querySelector('span.gD');
  const sender = senderEl
    ? (senderEl.getAttribute('email') || senderEl.textContent.trim())
    : '';

  const dateEl = document.querySelector('span.g3');
  const date = dateEl ? dateEl.getAttribute('title') || dateEl.textContent.trim() : '';

  const bodyEl = document.querySelector('div.a3s');
  const body = bodyEl ? bodyEl.innerText.trim() : '';

  const recipientEl = document.querySelector('span.g2');
  const recipient = recipientEl ? recipientEl.textContent.trim() : '';

  return { sender, recipient, subject, body, date, snippet: '', isUnread: false };
}
''';

  // ── JS: compose and send an email via Gmail's compose URL ────────────
  // Gmail's compose URL pre-fills fields; we wait for the compose window,
  // then click Send.
  static const _sendJs = r'''
() => {
  const sendBtn = document.querySelector('div[role="button"][aria-label*="Send"]')
                || document.querySelector('div.T-I.J-J5-Ji[role="button"]');
  if (sendBtn) {
    sendBtn.click();
    return { success: true, error: null };
  }
  return { success: false, error: 'Send button not found. The compose window may not have loaded.' };
}
''';

  // ── Config ───────────────────────────────────────────────────────────

  Future<void> loadConfig() async {
    _config = await GmailConfig.load();
    _chrome.configure(debugPort: _config.enabled ? _chrome.debugPort : _chrome.debugPort);
    notifyListeners();
  }

  Future<void> updateConfig(GmailConfig config) async {
    _config = config;
    await config.save();
    await _chrome.close();
    _connected = null;
    notifyListeners();
  }

  Future<void> copyLaunchCommand() async {
    await Clipboard.setData(ClipboardData(text: _chrome.launchCommand));
  }

  Future<bool> testConnection() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final ok = await _chrome.isDebugPortOpen();
      _connected = ok;
      _error = ok ? null : 'Chrome not found on port ${_chrome.debugPort}';
    } catch (e) {
      _connected = false;
      _error = e.toString().split('\n').first;
    } finally {
      _loading = false;
      notifyListeners();
    }
    return _connected ?? false;
  }

  // ── Send email ──────────────────────────────────────────────────────

  Future<bool> sendEmail(String to, String subject, String body) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final encodedSubject = Uri.encodeComponent(subject);
      final encodedBody = Uri.encodeComponent(body);
      final url =
          'https://mail.google.com/mail/?view=cm&fs=1'
          '&to=${Uri.encodeComponent(to)}'
          '&su=$encodedSubject'
          '&body=$encodedBody';
      _log.i('Sending email via: $url');

      final raw = await _chrome.navigateAndEvaluate(
        url,
        _sendJs,
        renderDelay: const Duration(seconds: 4),
      );
      final result = Map<String, dynamic>.from(raw as Map);

      final success = result['success'] as bool? ?? false;
      if (!success) {
        _error = result['error'] as String? ?? 'Failed to send email';
      }
      _connected = true;
      _log.i('Send result: $result');
      return success;
    } catch (e, st) {
      _log.e('Email send failed', error: e, stackTrace: st);
      _error = 'Send failed: ${e.toString().split('\n').first}';
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Search emails ───────────────────────────────────────────────────

  Future<EmailSearchResult?> searchEmails(String query) async {
    if (query.trim().isEmpty) {
      _error = 'Enter a search query';
      notifyListeners();
      return null;
    }

    _loading = true;
    _error = null;
    _lastSearch = null;
    _lastRead = null;
    notifyListeners();

    try {
      final encoded = Uri.encodeComponent(query.trim());
      final url = 'https://mail.google.com/mail/u/0/#search/$encoded';
      _log.i('Searching Gmail: $url');

      final raw = await _chrome.navigateAndEvaluate<List<dynamic>>(
        url,
        _searchJs,
        renderDelay: const Duration(seconds: 5),
      );

      final emails = raw
          .whereType<Map>()
          .map((m) => EmailInfo.fromMap(Map<String, dynamic>.from(m)))
          .toList();

      final result = EmailSearchResult(
        query: query,
        emails: emails,
        lastUpdated: DateTime.now(),
      );
      _lastSearch = result;
      _connected = true;
      _error = emails.isEmpty ? 'No emails found for "$query"' : null;
      _log.i('Search result: ${emails.length} email(s)');
    } catch (e, st) {
      _log.e('Gmail search failed', error: e, stackTrace: st);
      _error = 'Search failed: ${e.toString().split('\n').first}';
    } finally {
      _loading = false;
      notifyListeners();
    }

    return _lastSearch;
  }

  // ── Read a specific email ───────────────────────────────────────────

  Future<EmailInfo?> readEmail(String query, {int index = 0}) async {
    _loading = true;
    _error = null;
    _lastRead = null;
    notifyListeners();

    try {
      final encoded = Uri.encodeComponent(query.trim());
      final url = 'https://mail.google.com/mail/u/0/#search/$encoded';
      _log.i('Opening email #$index from search: $url');

      final browser = await _chrome.ensureBrowser();
      final page = await browser.newPage();
      try {
        try {
          await page.goto(url,
              wait: Until.domContentLoaded,
              timeout: const Duration(seconds: 20));
        } on TimeoutException {
          _log.w('Navigation timed out for $url — proceeding');
        }
        await Future<void>.delayed(const Duration(seconds: 5));

        // Click the Nth result row to open the email
        await page.evaluate('''
          () => {
            const rows = document.querySelectorAll('tr.zA');
            if (rows[$index]) rows[$index].click();
          }
        ''');
        await Future<void>.delayed(const Duration(seconds: 4));

        final raw = await page.evaluate(_readJs);
        final info = EmailInfo.fromMap(Map<String, dynamic>.from(raw as Map));
        _lastRead = info;
        _connected = true;
        _error = info.hasContent ? null : 'Could not parse email content';
        _log.i('Read result: $info');
      } finally {
        await page.close();
      }
    } catch (e, st) {
      _log.e('Email read failed', error: e, stackTrace: st);
      _error = 'Read failed: ${e.toString().split('\n').first}';
    } finally {
      _loading = false;
      notifyListeners();
    }

    return _lastRead;
  }

  Future<void> shutdown() async {
    await _chrome.close();
  }

  @override
  void dispose() {
    _chrome.dispose();
    super.dispose();
  }
}
