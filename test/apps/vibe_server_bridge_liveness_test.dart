/// Single-instance re-mount liveness (MOD-INFRA-010 §10.7 gap G-3).
///
/// App Builder is single-instance — one domain, one project, never two
/// concurrent mounts. The only hazard is a *re-mount* (IndexedStack
/// rebuild, re-open, hot restart): the old mount's bridge is torn down
/// while a tool/resource handler might still read it. `vibe_*` handlers
/// read through [VibeServerBridge.resolve] so they answer from the
/// currently-live mount, never a disposed one. This is *liveness*, not a
/// foreground gate — a backgrounded-but-mounted App Builder still answers
/// its real project state.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/app_builder/infra/vibe_server_bridge.dart';

void main() {
  tearDown(() => VibeServerBridge.live = null);

  test('resolve falls back to the captured bridge when none is live', () {
    final captured = VibeServerBridge();
    expect(VibeServerBridge.resolve(captured), same(captured));
  });

  test('resolve routes to the LIVE mount, not a torn-down captured one', () {
    final old = VibeServerBridge(); // mount that registered, then disposed
    final live = VibeServerBridge(); // current live mount after re-mount
    VibeServerBridge.markLive(live);
    expect(VibeServerBridge.resolve(old), same(live));
  });

  test('a handler reads the live mount getProject, not the disposed one', () {
    var oldRan = false;
    var liveRan = false;
    final old =
        VibeServerBridge()
          ..getProject = () {
            oldRan = true;
            return null;
          };
    final live =
        VibeServerBridge()
          ..getProject = () {
            liveRan = true;
            return null;
          };
    VibeServerBridge.markLive(live);

    // Mirrors ServerBootstrap's `_bridge` getter: resolve(captured).
    VibeServerBridge.resolve(old).getProject?.call();

    expect(liveRan, isTrue, reason: 'live mount getProject is the one read');
    expect(oldRan, isFalse, reason: 'the disposed captured bridge is NOT read');
  });

  test('clearLiveIfMine is only-if-mine — a re-mount swap is never undone', () {
    final a = VibeServerBridge();
    final b = VibeServerBridge();
    VibeServerBridge.markLive(a); // first mount
    VibeServerBridge.markLive(b); // re-mount swaps to b

    VibeServerBridge.clearLiveIfMine(a); // a's late dispose must not clear b
    expect(VibeServerBridge.live, same(b));

    VibeServerBridge.clearLiveIfMine(b); // b disposes while live
    expect(VibeServerBridge.live, isNull);
  });
}
