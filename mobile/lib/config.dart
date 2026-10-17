class AppConfig {
  static const String googleScriptUrl = String.fromEnvironment(
    'GOOGLE_SCRIPT_URL',
    defaultValue: '',
  );

  static const String appName = 'Geo Attendance';
  static const String appVersion = '0.2.1';

  static bool get hasValidScriptUrl {
    final uri = Uri.tryParse(googleScriptUrl);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'script.google.com' &&
        uri.path.contains('/macros/s/') &&
        uri.path.endsWith('/exec');
  }
}
