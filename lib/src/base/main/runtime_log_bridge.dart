/// Routes what the UI DSL runtime says to the studio's log surface.
///
/// The runtime carries two kinds of message. Most are for whoever is debugging
/// the app and go to `dart:developer` — fine, DevTools reads that. Some are for
/// **the person writing the document**: a theme role declared and dropped, a
/// widget placed under a key its type does not declare. Those only reach a host
/// that installs `MCPLogger.onRecord`, and the studio installed nothing — so an
/// authoring surface swallowed exactly the diagnostics authoring needs.
///
/// Measured, and expensively: a `lottieAnimation` written under `box.content`
/// (the slot is `child`) never mounted, drew nothing, and reported nothing. A
/// day went into chasing the runtime, the recipe and the capability wiring
/// before the document itself turned out to be at fault. The runtime now says
/// so — this is the wire that lets the studio hear it.
///
/// Bridged onto `package:logging` rather than a new channel because the debug
/// surface already drains `Logger.root` into the ring buffer behind
/// `vibe_logs_tail` / `vibe_runtime_errors`. One sink, one place to look.
library;

import 'package:logging/logging.dart' as logging;

import 'package:appplayer_studio/runtime.dart' as studio_rt;

/// Installed once at host boot; guards against a second install replacing the
/// first (the sink is a single static slot, so the last writer would win).
bool _installed = false;

/// Sends every runtime record to `Logger('mcp_ui_runtime')`.
///
/// Levels are mapped rather than flattened: the debug surface drops unscoped
/// records below INFO, and a dropped-widget warning arriving as FINE would be
/// filtered out exactly where it matters.
void installRuntimeLogBridge() {
  if (_installed) return;
  _installed = true;
  final log = logging.Logger('mcp_ui_runtime');
  studio_rt.MCPLogger.onRecord = (record) {
    final level = switch (record.level.toUpperCase()) {
      'ERROR' => logging.Level.SEVERE,
      'WARN' || 'WARNING' => logging.Level.WARNING,
      'INFO' => logging.Level.INFO,
      _ => logging.Level.FINE,
    };
    log.log(level, '[${record.logger}] ${record.message}');
  };
}

/// Test seam: forget the install so a test can assert the guard.
void resetRuntimeLogBridgeForTest() {
  _installed = false;
  studio_rt.MCPLogger.onRecord = null;
}
