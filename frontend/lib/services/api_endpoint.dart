/// Deployment address supplied when building the app. An empty value retains
/// the team's existing local-development defaults.
String deploymentApiBaseUrl(String configured, String fallback) {
  final raw = configured.trim();
  if (raw.isEmpty) return fallback;
  final value = raw.replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !const ['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw ArgumentError(
      'MISBAR_API_BASE_URL must be an HTTP(S) server address.',
    );
  }
  return value;
}
