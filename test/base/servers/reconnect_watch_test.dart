/// Platform spec 17 §7.6d / §7.6e, pinned as behaviour.
///
/// Each group states one rule the spec makes and one way the implementation
/// could quietly stop honouring it. The bug this axis came from was not a crash
/// — it was a reconnect that silently stopped happening — so every assertion
/// here is about what KEEPS happening over elapsed time, not about a return
/// value. Virtual time makes "still dialling ten minutes later" cheap to state.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:appplayer_studio/src/base/servers/reconnect_watch.dart';

void main() {
  group('no attempt cap (§7.6d MUST)', () {
    // These pin the RETRY LOOP itself, so detection is pushed far out of the
    // way. It is not decoration: the detect tick re-arms a loop that has
    // exited, which would mask a cap inside the loop and let exactly the
    // AppPlayer bug back in wearing a different hat. With detection unable to
    // help, "still dialling" can only mean the loop never gave up.
    const noDetectRearm = Duration(hours: 24);

    test('keeps dialling for as long as a view holds the id', () {
      fakeAsync((async) {
        var dials = 0;
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async => dials++,
          detectInterval: noDetectRearm,
          retryInterval: const Duration(seconds: 5),
        );
        watch.hold('board');
        async.elapse(const Duration(minutes: 10));

        // 10 minutes at one dial per 5s. Any counter-based ceiling — the exact
        // shape of the AppPlayer bug — lands far below this.
        expect(dials, greaterThan(100));
        watch.dispose();
      });
    });

    test('a long outage does not exhaust it: dialling survives an hour', () {
      fakeAsync((async) {
        var dials = 0;
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async => dials++,
          detectInterval: noDetectRearm,
          retryInterval: const Duration(seconds: 5),
        );
        watch.hold('board');
        async.elapse(const Duration(hours: 1));
        final afterAnHour = dials;
        async.elapse(const Duration(minutes: 5));

        expect(dials, greaterThan(afterAnHour),
            reason: 'the loop stopped some time before the device came back');
        watch.dispose();
      });
    });
  });

  group('detection and retry are separate knobs (§7.6d MUST)', () {
    int dialsOver(Duration span, {required Duration detect}) {
      var dials = 0;
      fakeAsync((async) {
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async => dials++,
          detectInterval: detect,
          retryInterval: const Duration(seconds: 5),
        );
        watch.hold('board');
        async.elapse(span);
        watch.dispose();
      });
      return dials;
    }

    test('tightening detection does not accelerate dialling', () {
      const span = Duration(minutes: 2);
      final slowDetect = dialsOver(span, detect: const Duration(seconds: 2));
      final fastDetect =
          dialsOver(span, detect: const Duration(milliseconds: 100));

      // The regression being locked out: one knob feeding both, so lowering
      // detection to notice drops sooner multiplies the dial rate — which is
      // how the original bug burned its budget in ~15 seconds.
      expect(fastDetect, slowDetect);
    });
  });

  group('dials never overlap (§7.6d MUST)', () {
    test('a dial slower than the interval is not stacked on', () {
      fakeAsync((async) {
        var inFlight = 0;
        var maxInFlight = 0;
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async {
            inFlight++;
            if (inFlight > maxInFlight) maxInFlight = inFlight;
            await Future<void>.delayed(const Duration(seconds: 12));
            inFlight--;
          },
          retryInterval: const Duration(seconds: 5),
          dialTimeout: const Duration(seconds: 30),
        );
        watch.hold('board');
        async.elapse(const Duration(minutes: 3));

        // Single-peer boards (spec 17 §7.6b) have the newer session reset the
        // older one, so overlapping dials make recovery worse, not faster.
        expect(maxInFlight, 1);
        watch.dispose();
      });
    });
  });

  group('a dial is bounded (§7.6d MUST)', () {
    test('a hung dial is timed out so the loop continues', () {
      fakeAsync((async) {
        var started = 0;
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) {
            started++;
            return Completer<void>().future; // never settles
          },
          retryInterval: const Duration(seconds: 5),
          dialTimeout: const Duration(seconds: 15),
        );
        watch.hold('board');
        async.elapse(const Duration(minutes: 2));

        // Without the ceiling the first attempt hangs forever and retrying
        // stops just as completely as giving up would.
        expect(started, greaterThan(2));
        watch.dispose();
      });
    });
  });

  group('signals cut the wait, they do not replace it (§7.6e)', () {
    test('hintReachable dials before the interval would have', () {
      fakeAsync((async) {
        var dials = 0;
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async => dials++,
          detectInterval: const Duration(seconds: 30),
          retryInterval: const Duration(minutes: 5),
        );
        watch.hold('board');
        async.flushMicrotasks();
        expect(dials, 1, reason: 'mount dials once immediately');

        async.elapse(const Duration(seconds: 1));
        expect(dials, 1, reason: 'still inside the 5-minute gap');

        watch.hintReachable('board');
        async.flushMicrotasks();

        expect(dials, 2, reason: 'the sighting did not shorten the wait');
        watch.dispose();
      });
    });

    test('a hint for another id does not dial this one', () {
      fakeAsync((async) {
        final dials = <String, int>{};
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (id) async => dials[id] = (dials[id] ?? 0) + 1,
          detectInterval: const Duration(seconds: 30),
          retryInterval: const Duration(minutes: 5),
        );
        watch.hold('a');
        watch.hold('b');
        async.flushMicrotasks();
        final before = dials['b'];

        watch.hintReachable('a');
        async.flushMicrotasks();

        expect(dials['b'], before);
        watch.dispose();
      });
    });

    test('the timed loop still runs when no signal ever arrives', () {
      fakeAsync((async) {
        var dials = 0;
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async => dials++,
          retryInterval: const Duration(seconds: 5),
        );
        watch.hold('cloud');
        async.elapse(const Duration(minutes: 1));

        // An https endpoint is never sighted locally; the floor is all it has.
        expect(dials, greaterThan(5));
        watch.dispose();
      });
    });
  });

  group('network-regain edge (§7.6e)', () {
    test('fires on offline→online only', () {
      fakeAsync((async) {
        var dials = 0;
        final online = StreamController<bool>();
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async => dials++,
          detectInterval: const Duration(seconds: 30),
          retryInterval: const Duration(minutes: 5),
        );
        watch.hold('cloud');
        watch.bindOnlineChanges(online.stream);
        async.flushMicrotasks();
        final afterMount = dials;

        online.add(true); // first event: a state report, not a transition
        async.flushMicrotasks();
        expect(dials, afterMount, reason: 'bind-time state dialled');

        online.add(true); // platforms repeat "connected" per interface
        async.flushMicrotasks();
        expect(dials, afterMount, reason: 'a repeat counted as a transition');

        online.add(false);
        async.flushMicrotasks();
        expect(dials, afterMount);

        online.add(true); // the real edge
        async.flushMicrotasks();
        expect(dials, afterMount + 1);

        watch.dispose();
        online.close();
      });
    });
  });

  group('retrying is bounded by open apps', () {
    test('release stops the loop', () {
      fakeAsync((async) {
        var dials = 0;
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async => dials++,
          retryInterval: const Duration(seconds: 5),
        );
        watch.hold('board');
        async.elapse(const Duration(seconds: 30));
        final whileOpen = dials;
        expect(whileOpen, greaterThan(1));

        watch.release('board');
        async.elapse(const Duration(minutes: 5));

        expect(dials, whileOpen, reason: 'a closed view kept a radio dialling');
        watch.dispose();
      });
    });

    test('two views on one id: the first close does not stop the second', () {
      fakeAsync((async) {
        var dials = 0;
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async => dials++,
          retryInterval: const Duration(seconds: 5),
        );
        watch.hold('board');
        watch.hold('board');
        watch.release('board');
        async.elapse(const Duration(seconds: 30));
        final withOneLeft = dials;

        watch.release('board');
        async.elapse(const Duration(minutes: 5));

        expect(withOneLeft, greaterThan(1),
            reason: 'the surviving view stopped being served');
        expect(dials, withOneLeft);
        watch.dispose();
      });
    });

    test('a recovered connection ends the loop', () {
      fakeAsync((async) {
        final live = <String>{};
        var dials = 0;
        final watch = StudioReconnectWatch(
          isLive: live.contains,
          dial: (id) async {
            dials++;
            if (dials >= 3) live.add(id);
          },
          retryInterval: const Duration(seconds: 5),
        );
        watch.hold('board');
        async.elapse(const Duration(minutes: 2));

        expect(dials, 3, reason: 'kept dialling a connection already back');
        watch.dispose();
      });
    });
  });

  group('stalled set scopes observation (§7.6e MUST)', () {
    test('is held ∩ dead, and drops ids with no route back', () {
      fakeAsync((async) {
        final live = <String>{'up'};
        final watch = StudioReconnectWatch(
          isLive: live.contains,
          dial: (_) async {},
          canDial: (id) => id != 'unreachable',
          retryInterval: const Duration(seconds: 5),
        );
        watch.hold('up');
        watch.hold('down');
        watch.hold('unreachable');
        async.flushMicrotasks();

        // A live connection needs no watching; an id with no dial route cannot
        // be recovered by any signal, so listening for it is a radio left on
        // for nothing.
        expect(watch.stalledServers, <String>{'down'});
        watch.dispose();
      });
    });

    test('an undialable id is never dialled', () {
      fakeAsync((async) {
        var dials = 0;
        final watch = StudioReconnectWatch(
          isLive: (_) => false,
          dial: (_) async => dials++,
          canDial: (_) => false,
          retryInterval: const Duration(seconds: 5),
        );
        watch.hold('nowhere');
        async.elapse(const Duration(minutes: 5));

        expect(dials, 0);
        watch.dispose();
      });
    });
  });
}
