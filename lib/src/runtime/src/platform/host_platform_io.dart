import 'dart:io';

/// The host this process is running on, as the DSL names it.
String get hostPlatformName {
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  if (Platform.isFuchsia) return 'fuchsia';
  return 'unknown';
}

/// Host OS version string, or `unknown` where the host will not say.
String get hostOsVersion {
  try {
    return Platform.operatingSystemVersion;
  } catch (_) {
    return 'unknown';
  }
}

/// Path separator for the host filesystem.
String get hostPathSeparator => Platform.pathSeparator;

/// Logged-in user, where the host exposes one.
String? get hostUserName =>
    Platform.environment['USER'] ??
    Platform.environment['USERNAME'] ??
    Platform.environment['LOGNAME'];

/// One environment variable, where the host exposes an environment.
String? hostEnv(String name) => Platform.environment[name];

/// Current working directory, where the host has one.
String? get hostWorkingDirectory {
  try {
    return Directory.current.path;
  } catch (_) {
    return null;
  }
}

/// Number of processors the host reports.
int get hostProcessorCount => Platform.numberOfProcessors;

/// Resident set size and peak, in bytes.
({int rss, int maxRss}) get hostMemory =>
    (rss: ProcessInfo.currentRss, maxRss: ProcessInfo.maxRss);
