/// Who the runtime is running on, answered once.
///
/// A UI runtime asking `dart:io` which operating system it is on puts the
/// decision in the wrong layer: the widget and binding code then branches on
/// the host directly, needs a `kIsWeb` guard at every one of those branches,
/// and cannot be told otherwise by the embedder that actually knows. This
/// package already keeps platform powers on the other side of a port
/// (`RuntimeCapabilities`, and the conditional imports behind `speech` and
/// `pdfView`); platform identity belongs there for the same reason.
///
/// So: `dart:io` is read in exactly one file, the web build never compiles it,
/// and everything above reads [name] — including a host that knows better than
/// the process does. A kiosk shell, a remote session, or a test says so with
/// [override].
library host_platform;

import 'host_platform_io.dart'
    if (dart.library.js_interop) 'host_platform_web.dart' as impl;

/// Identity of the client this runtime is running on.
abstract final class HostPlatform {
  static String? _name;

  /// One of `macos`, `linux`, `windows`, `ios`, `android`, `web` — or
  /// `unknown` where the host will not say.
  static String get name => _name ?? impl.hostPlatformName;

  /// `mobile`, `desktop`, `web`, or `unknown`.
  ///
  /// Derived from [name] rather than read separately: two independent
  /// readings of the same fact can disagree, and a document branching on both
  /// would then see a mobile platform in a desktop category.
  static String get category => switch (name) {
        'android' || 'ios' => 'mobile',
        'macos' || 'windows' || 'linux' => 'desktop',
        'web' => 'web',
        _ => 'unknown',
      };

  /// Whether this is a browser.
  static bool get isWeb => name == 'web';

  /// Host OS version string.
  static String get osVersion => _osVersion ?? impl.hostOsVersion;
  static String? _osVersion;

  /// Path separator for the host filesystem.
  static String get pathSeparator => impl.hostPathSeparator;

  /// Logged-in user, where the host exposes one.
  static String? get userName => impl.hostUserName;

  /// Current working directory, where the host has one.
  static String? get workingDirectory => impl.hostWorkingDirectory;

  /// One environment variable, where the host exposes an environment.
  ///
  /// The allowlist and the `system.info` permission gate stay with the
  /// caller — this only reads.
  static String? env(String name) => impl.hostEnv(name);

  /// Number of processors the host reports.
  static int get processorCount => impl.hostProcessorCount;

  /// Resident set size and peak, in bytes.
  static ({int rss, int maxRss}) get memory => impl.hostMemory;

  /// States the identity, for an embedder that knows better than the process
  /// does — and for tests. Passing null restores the platform's own answer.
  static void override({String? name, String? osVersion}) {
    _name = name;
    _osVersion = osVersion;
  }

  /// Restores the platform's own answer.
  static void clearOverride() => override();
}
