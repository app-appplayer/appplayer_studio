/// Ops tab-close teardown gate (`OpsBuiltInApp.shouldTeardownOnClose`).
///
/// Design contract (knowledge-operations.md §11.3): a tab CLOSE tears the
/// backend down; a tab SWITCH keeps it running in the background. The Ops
/// shell disposes only on tab close (the host renders bodies in a keyed
/// IndexedStack), so `dispose()` calling `resetBootCache()` is the close
/// path. The gate here guards WHICH close triggers teardown: only the tab
/// that owns the live boot — never a stale sibling, a project-less tab, or
/// a project already closed via the header button.
library;

import 'package:appplayer_studio/apps.dart' show OpsBuiltInApp;
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    // Leave the process-wide marker clean between cases.
    OpsBuiltInApp.debugSetBootedProject(null);
  });

  test('owning / MCP-only-boot tabs tear down; divergent does not', () {
    OpsBuiltInApp.debugSetBootedProject('/projects/alpha');

    // The tab bound to the booted project → teardown.
    expect(OpsBuiltInApp.shouldTeardownOnClose('/projects/alpha'), isTrue);
    // Shell never bound (backend booted MCP-only via ensureBoot, so
    // `_currentProject` stayed null) → the sole Ops tab owns the sole boot
    // → teardown. Regression guard for the MCP-only-boot leak.
    expect(OpsBuiltInApp.shouldTeardownOnClose(null), isTrue);
    // The tab bound a DIFFERENT project than what's booted (a race) →
    // leave the booted backend alone.
    expect(OpsBuiltInApp.shouldTeardownOnClose('/projects/beta'), isFalse);
  });

  test('no live boot → no teardown for any tab', () {
    OpsBuiltInApp.debugSetBootedProject(null);
    expect(OpsBuiltInApp.shouldTeardownOnClose('/projects/alpha'), isFalse);
    expect(OpsBuiltInApp.shouldTeardownOnClose(null), isFalse);
  });

  test('resetBootCache clears ownership → close no longer tears down', () {
    OpsBuiltInApp.debugSetBootedProject('/projects/alpha');
    expect(OpsBuiltInApp.shouldTeardownOnClose('/projects/alpha'), isTrue);
    // Header-button project close already ran teardown → marker cleared.
    OpsBuiltInApp.resetBootCache();
    // A subsequent tab close must not double-dispose.
    expect(OpsBuiltInApp.shouldTeardownOnClose('/projects/alpha'), isFalse);
  });
}
