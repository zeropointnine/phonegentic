// ignore_for_file: constant_identifier_names
class EnvConfig {
  static const ENV_NAME = String.fromEnvironment(
    'ENV_NAME',
    defaultValue: 'staging',
  );
  static const String GRAPHQL_API_HOST = String.fromEnvironment('GRAPHQL_API_HOST', defaultValue: 'REDACTED_GRAPHQL_HOST');
  static const String GRAPHQL_API_KEY = String.fromEnvironment('GRAPHQL_API_KEY', defaultValue: 'REDACTED_GRAPHQL_API_KEY');
  static const String REAL_TIME_API_HOST = String.fromEnvironment('REAL_TIME_API_HOST', defaultValue: 'REDACTED_REALTIME_HOST');
  static const String SEGMENT_API_KEY = String.fromEnvironment('SEGMENT_API_KEY', defaultValue: 'REDACTED_SEGMENT_API_KEY');
  static const String WEBSOCKET_ENDPOINT_HEALTH_CHECK_URL = String.fromEnvironment('WEBSOCKET_ENDPOINT_HEALTH_CHECK_URL', defaultValue: 'REDACTED_HEALTH_CHECK_URL');
  static const bool USE_ANSI_COLOR_IN_LOGS = String.fromEnvironment('USE_ANSI_COLOR_IN_LOGS', defaultValue: 'false') == 'true';
  static const bool LOGGING_ENABLED = String.fromEnvironment('LOGGING_ENABLED', defaultValue: 'false') == 'true';
  static const bool PRINT_DEBUG_LOGS = String.fromEnvironment('PRINT_DEBUG_LOGS', defaultValue: 'false') == 'true';
}
