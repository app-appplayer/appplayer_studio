/// The host this process is running on, as the DSL names it.
String get hostPlatformName => 'web';

/// A browser reports no OS version of its own.
String get hostOsVersion => 'web';

/// URLs, not filesystem paths.
String get hostPathSeparator => '/';

/// A browser has no logged-in OS user.
String? get hostUserName => null;

/// A browser has no process environment.
String? hostEnv(String name) => null;

/// A browser has no working directory.
String? get hostWorkingDirectory => null;

/// A browser does not report a processor count it can be held to.
int get hostProcessorCount => 1;

/// A browser exposes no process memory.
({int rss, int maxRss}) get hostMemory => (rss: 0, maxRss: 0);
