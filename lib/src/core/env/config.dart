// ignore_for_file: constant_identifier_names
class EnvConfig {
  static const bool USE_ANSI_COLOR_IN_LOGS =
      String.fromEnvironment('USE_ANSI_COLOR_IN_LOGS', defaultValue: 'false') ==
          'true';
  static const bool LOGGING_ENABLED =
      String.fromEnvironment('LOGGING_ENABLED', defaultValue: 'false') ==
          'true';
  static const bool PRINT_DEBUG_LOGS =
      String.fromEnvironment('PRINT_DEBUG_LOGS', defaultValue: 'false') ==
          'true';
}
