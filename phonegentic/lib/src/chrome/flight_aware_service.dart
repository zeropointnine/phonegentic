import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import 'chrome_browser_service.dart';
import 'flight_aware_config.dart';
import 'flight_info.dart';

class FlightAwareService extends ChangeNotifier {
  static final _log = Logger();

  final ChromeBrowserService _chrome = ChromeBrowserService();
  ChromeBrowserService get chrome => _chrome;

  FlightAwareConfig _config = const FlightAwareConfig();
  FlightAwareConfig get config => _config;

  FlightInfo? _lastFlight;
  FlightInfo? get lastFlight => _lastFlight;

  RouteSearchResult? _lastRoute;
  RouteSearchResult? get lastRoute => _lastRoute;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  bool? _connected;
  bool? get connected => _connected;

  // ── JS extraction for a single-flight page ───────────────────────────

  static const _flightJs = r'''
() => {
  const txt = document.body.innerText;
  const r = {
    flightNumber: '', airline: '', origin: '', destination: '',
    departureTime: null, arrivalTime: null, status: null, aircraft: null,
    gate: null,
  };

  const title = document.title || '';
  const fn = title.match(/^(\S+)/);
  if (fn) r.flightNumber = fn[1];

  const al = title.match(/\)\s+(.+?)\s+(Flight|Tracking)/i);
  if (al) r.airline = al[1].trim();

  // Origin / destination — rendered as "BWI\nBALTIMORE, MD"
  const blocks = txt.match(/([A-Z]{3,4})\n([A-Z ]+, [A-Z]{2})/g);
  if (blocks && blocks.length >= 2) {
    r.origin = blocks[0].replace('\n', ' - ');
    r.destination = blocks[1].replace('\n', ' - ');
  }

  // Times appear after date lines like "WEDNESDAY 08-APR-2026\n06:23AM EDT"
  // This skips the page header clock which stands alone.
  const dateTimePairs = [
    ...txt.matchAll(/[A-Z]+\s+\d{2}-[A-Z]{3}-\d{4}\n(\d{1,2}:\d{2}[AP]M\s+[A-Z]{2,4})/g)
  ];
  if (dateTimePairs.length >= 1) r.departureTime = dateTimePairs[0][1];
  if (dateTimePairs.length >= 2) r.arrivalTime = dateTimePairs[1][1];

  // Gate info
  const depGate = txt.match(/departing from\s+GATE\s+(\S+)/i);
  const arrGate = txt.match(/arriving at\s+GATE\s+(\S+)/i);
  if (depGate || arrGate) {
    r.gate = (depGate ? 'Dep Gate ' + depGate[1] : '')
           + (depGate && arrGate ? ', ' : '')
           + (arrGate ? 'Arr Gate ' + arrGate[1] : '');
  }

  // Status keywords
  const statusMatch = txt.match(
    /(?:EXPECTED TO DEPART|EN ROUTE|ARRIVED|LANDED|CANCELLED|DELAYED|DIVERTED|ON TIME|RESULT UNKNOWN)[^\n]*/i
  );
  if (statusMatch) r.status = statusMatch[0].trim();

  return r;
}
''';

  // ── JS extraction for the route-search table ─────────────────────────

  static const _routeJs = r'''
() => {
  const rows = document.querySelectorAll('table tr');
  const flights = [];
  for (const row of rows) {
    const cells = row.querySelectorAll('td');
    if (cells.length < 5) continue;
    const text = i => (cells[i]?.textContent || '').trim().replace(/\s+/g, ' ');
    flights.push({
      airline:       text(0),
      flightNumber:  text(1),
      aircraft:      text(2),
      status:        text(3),
      departureTime: text(4),
      arrivalTime:   text(6),
    });
  }
  return flights;
}
''';

  // ── Config ───────────────────────────────────────────────────────────

  Future<void> loadConfig() async {
    _config = await FlightAwareConfig.load();
    _chrome.configure(debugPort: _config.debugPort);
    notifyListeners();
  }

  Future<void> updateConfig(FlightAwareConfig config) async {
    _config = config;
    await config.save();
    await _chrome.close();
    _connected = null;
    _chrome.configure(debugPort: config.debugPort);
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

  // ── Lookup by flight number ──────────────────────────────────────────

  Future<FlightInfo?> lookupFlight(String flightNumber) async {
    final normalized = flightNumber.trim().toUpperCase().replaceAll(' ', '');
    if (normalized.isEmpty) {
      _error = 'Enter a flight number';
      notifyListeners();
      return null;
    }

    _loading = true;
    _error = null;
    _lastFlight = null;
    _lastRoute = null;
    notifyListeners();

    try {
      final url =
          'https://www.flightaware.com/live/flight/$normalized';
      _log.i('Looking up flight: $url');

      final raw = await _chrome.navigateAndEvaluate<Map<String, dynamic>>(
        url, _flightJs,
      );

      final info = FlightInfo.fromMap({...raw, 'flightNumber': normalized});
      _lastFlight = info;
      _connected = true;
      _error = info.hasRoute ? null : 'Could not parse flight data';
      _log.i('Flight result: $info');
    } catch (e, st) {
      _log.e('Flight lookup failed', error: e, stackTrace: st);
      _error = 'Lookup failed: ${e.toString().split('\n').first}';
    } finally {
      _loading = false;
      notifyListeners();
    }

    return _lastFlight;
  }

  // ── Search by route (origin → destination) ───────────────────────────

  Future<RouteSearchResult?> searchRoute(
      String origin, String destination) async {
    final o = origin.trim().toUpperCase();
    final d = destination.trim().toUpperCase();
    if (o.isEmpty || d.isEmpty) {
      _error = 'Enter both origin and destination';
      notifyListeners();
      return null;
    }

    _loading = true;
    _error = null;
    _lastFlight = null;
    _lastRoute = null;
    notifyListeners();

    try {
      final url =
          'https://www.flightaware.com/live/findflight/$o/$d';
      _log.i('Searching route: $url');

      final raw = await _chrome.navigateAndEvaluate<List<dynamic>>(
        url, _routeJs,
      );

      final flights = raw
          .cast<Map<String, dynamic>>()
          .map((m) => FlightInfo.fromMap(m))
          .toList();

      final result = RouteSearchResult(
        origin: o,
        destination: d,
        flights: flights,
        lastUpdated: DateTime.now(),
      );
      _lastRoute = result;
      _connected = true;
      _error = flights.isEmpty ? 'No flights found for $o → $d' : null;
      _log.i('Route result: ${flights.length} flight(s)');
    } catch (e, st) {
      _log.e('Route search failed', error: e, stackTrace: st);
      _error = 'Search failed: ${e.toString().split('\n').first}';
    } finally {
      _loading = false;
      notifyListeners();
    }

    return _lastRoute;
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
