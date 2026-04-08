class FlightInfo {
  final String flightNumber;
  final String airline;
  final String origin;
  final String destination;
  final String? departureTime;
  final String? arrivalTime;
  final String? status;
  final String? aircraft;
  final String? gate;
  final DateTime lastUpdated;

  const FlightInfo({
    required this.flightNumber,
    this.airline = '',
    this.origin = '',
    this.destination = '',
    this.departureTime,
    this.arrivalTime,
    this.status,
    this.aircraft,
    this.gate,
    required this.lastUpdated,
  });

  bool get hasRoute => origin.isNotEmpty && destination.isNotEmpty;

  factory FlightInfo.fromMap(Map<String, dynamic> m) {
    return FlightInfo(
      flightNumber: (m['flightNumber'] as String?) ?? '',
      airline: (m['airline'] as String?) ?? '',
      origin: (m['origin'] as String?) ?? '',
      destination: (m['destination'] as String?) ?? '',
      departureTime: m['departureTime'] as String?,
      arrivalTime: m['arrivalTime'] as String?,
      status: m['status'] as String?,
      aircraft: m['aircraft'] as String?,
      gate: m['gate'] as String?,
      lastUpdated: DateTime.now(),
    );
  }

  @override
  String toString() =>
      'FlightInfo($flightNumber $origin→$destination status=$status)';
}

/// Parsed from the FlightAware route search table.
class RouteSearchResult {
  final String origin;
  final String destination;
  final List<FlightInfo> flights;
  final DateTime lastUpdated;

  const RouteSearchResult({
    required this.origin,
    required this.destination,
    required this.flights,
    required this.lastUpdated,
  });
}
