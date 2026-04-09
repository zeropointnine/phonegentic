import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import 'chrome_browser_service.dart';
import 'google_search_config.dart';
import 'google_search_models.dart';

class GoogleSearchService extends ChangeNotifier {
  static final _log = Logger();

  final ChromeBrowserService _chrome = ChromeBrowserService();
  ChromeBrowserService get chrome => _chrome;

  GoogleSearchConfig _config = const GoogleSearchConfig();
  GoogleSearchConfig get config => _config;

  GoogleSearchResult? _lastSearch;
  GoogleSearchResult? get lastSearch => _lastSearch;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  bool? _connected;
  bool? get connected => _connected;

  // ── JS: scrape Google search results page ───────────────────────────

  static const _searchJs = r'''
() => {
  const results = [];
  const seen = new Set();

  // Strategy: find every h3 inside the main search area, then walk up to
  // the nearest ancestor that contains both the link and a snippet.
  const headings = document.querySelectorAll('#search h3, #rso h3, #main h3');
  for (const h3 of headings) {
    const title = h3.textContent.trim();
    if (!title) continue;

    // Walk up to find the containing result block (at most 6 levels)
    let block = h3.parentElement;
    for (let i = 0; i < 6 && block; i++) {
      if (block.querySelector('a[href^="http"]') && block.querySelector('span, div[data-sncf], [class*="VwiC3b"]')) break;
      block = block.parentElement;
    }
    if (!block) continue;

    const linkEl = block.querySelector('a[href^="http"]');
    const url = linkEl ? linkEl.href : '';

    // De-dup by URL
    const key = url || title;
    if (seen.has(key)) continue;
    seen.add(key);

    // Snippet: grab the longest text node sibling that isn't the title
    let snippet = '';
    const spans = block.querySelectorAll('span, div[data-sncf], [class*="VwiC3b"], [class*="IsZvec"], em');
    let best = '';
    for (const s of spans) {
      const txt = s.textContent.trim();
      if (txt.length > best.length && txt !== title && !txt.startsWith('http')) {
        best = txt;
      }
    }
    snippet = best;

    results.push({ title, url, snippet });
  }
  return results;
}
''';

  // ── Config ───────────────────────────────────────────────────────────

  Future<void> loadConfig() async {
    _config = await GoogleSearchConfig.load();
    notifyListeners();
  }

  Future<void> updateConfig(GoogleSearchConfig config) async {
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

  // ── Search Google ───────────────────────────────────────────────────

  Future<GoogleSearchResult?> searchGoogle(String query) async {
    if (query.trim().isEmpty) {
      _error = 'Enter a search query';
      notifyListeners();
      return null;
    }

    _loading = true;
    _error = null;
    _lastSearch = null;
    notifyListeners();

    try {
      final encoded = Uri.encodeComponent(query.trim());
      final url = 'https://www.google.com/search?q=$encoded';
      _log.i('Searching Google: $url');

      final raw = await _chrome.navigateAndEvaluate<List<dynamic>>(
        url,
        _searchJs,
        renderDelay: const Duration(seconds: 3),
      );

      final items = raw
          .whereType<Map>()
          .map((m) =>
              GoogleSearchResultItem.fromMap(Map<String, dynamic>.from(m)))
          .toList();

      final result = GoogleSearchResult(
        query: query,
        items: items,
        lastUpdated: DateTime.now(),
      );
      _lastSearch = result;
      _connected = true;
      _error = items.isEmpty ? 'No results found for "$query"' : null;
      _log.i('Search result: ${items.length} item(s)');
    } catch (e, st) {
      _log.e('Google search failed', error: e, stackTrace: st);
      _error = 'Search failed: ${e.toString().split('\n').first}';
    } finally {
      _loading = false;
      notifyListeners();
    }

    return _lastSearch;
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
