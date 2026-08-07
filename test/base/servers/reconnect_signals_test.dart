/// Signal sources feeding the reconnect watch (spec 17 §7.6e).
///
/// Two claims are worth locking. The scheme routing decides WHICH connections
/// can be observed at all — get it wrong and either a board is never listened
/// for, or a radio is started for an https endpoint nothing local can ever
/// sight. And resume must fire on the EDGE: a host that reports "resumed" while
/// already foregrounded is not news, and dialling on it would put the studio
/// back to hinting on a timer it does not control.
@TestOn('vm')
library;

import 'package:appplayer_studio/src/base/servers/reconnect_signals.dart';
import 'package:appplayer_studio/src/base/servers/reconnect_watch.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sighting endpoints', () {
    test('a BLE connection id routes to a watchable endpoint', () {
      expect(studioSightingEndpoint('ble:AA-BB-CC'), 'ble://AA-BB-CC');
    });

    test('anything without a device to observe routes nowhere', () {
      // An https server is recovered by the loop, not by a radio — returning an
      // endpoint here would start a scan that can never see it.
      expect(studioSightingEndpoint('https://api.example.com/mcp'), isNull);
      expect(studioSightingEndpoint('board:acme.thing'), isNull);
      // Degenerate ids must not become `ble://` with nothing after it.
      expect(studioSightingEndpoint('ble:'), isNull);
      expect(studioSightingEndpoint('ble://already'), isNull);
    });
  });

  group('resume hint', () {
    late List<String> dialled;
    late StudioReconnectWatch watch;

    setUp(() {
      dialled = <String>[];
      watch = StudioReconnectWatch(
        isLive: (_) => false,
        dial: (id) async => dialled.add(id),
        detectInterval: const Duration(minutes: 10),
        retryInterval: const Duration(minutes: 10),
      );
    });

    tearDown(() => watch.dispose());

    testWidgets('resuming after an interruption asks for a dial',
        (tester) async {
      final hint = StudioResumeHint(watch)..start();
      addTearDown(hint.stop);
      watch.hold('board');
      await tester.pump();
      dialled.clear();

      // The shape a machine waking from sleep reports.
      hint.didChangeAppLifecycleState(AppLifecycleState.inactive);
      hint.didChangeAppLifecycleState(AppLifecycleState.resumed);
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }

      expect(dialled, <String>['board']);
      watch.dispose(); // ends the watch's timers inside the test body
    });

    testWidgets('an unchanged foreground state is not a signal',
        (tester) async {
      final hint = StudioResumeHint(watch)..start();
      addTearDown(hint.stop);
      watch.hold('board');
      await tester.pump();
      dialled.clear();

      // First report of the current state, then the same state again: neither
      // is a transition, so neither may dial.
      hint.didChangeAppLifecycleState(AppLifecycleState.resumed);
      hint.didChangeAppLifecycleState(AppLifecycleState.resumed);
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }

      expect(dialled, isEmpty);
      watch.dispose(); // ends the watch's timers inside the test body
    });
  });
}
