/// Unit tests for the R24 internal-call guard infrastructure
/// (`ChromeBridge.internalCallsEnabled` + `withInternalCalls` helper
/// + `internalGuard` reject envelope).
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/install/internal_call_guard.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';

void main() {
  group('ChromeBridge.internalCallsEnabled', () {
    test('defaults to false', () {
      final bridge = ChromeBridge();
      expect(bridge.internalCallsEnabled, isFalse);
    });

    test('direct mutation flips the flag', () {
      final bridge = ChromeBridge();
      bridge.internalCallsEnabled = true;
      expect(bridge.internalCallsEnabled, isTrue);
      bridge.internalCallsEnabled = false;
      expect(bridge.internalCallsEnabled, isFalse);
    });
  });

  group('ChromeBridge.withInternalCalls', () {
    test('forces the flag on for the body and restores it after', () async {
      final bridge = ChromeBridge();
      expect(bridge.internalCallsEnabled, isFalse);
      final captured = <bool>[];
      await bridge.withInternalCalls(() async {
        captured.add(bridge.internalCallsEnabled);
        return null;
      });
      expect(captured, [true]);
      expect(bridge.internalCallsEnabled, isFalse);
    });

    test('restores the previous value when nested', () async {
      final bridge = ChromeBridge();
      bridge.internalCallsEnabled = true; // outer caller already in context
      await bridge.withInternalCalls(() async {
        expect(bridge.internalCallsEnabled, isTrue);
        return null;
      });
      expect(bridge.internalCallsEnabled, isTrue); // outer value preserved
    });

    test('restores the flag even when the body throws', () async {
      final bridge = ChromeBridge();
      expect(bridge.internalCallsEnabled, isFalse);
      Object? caught;
      try {
        await bridge.withInternalCalls<void>(() async {
          expect(bridge.internalCallsEnabled, isTrue);
          throw StateError('boom');
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      expect(bridge.internalCallsEnabled, isFalse);
    });

    test('passes the body return value through', () async {
      final bridge = ChromeBridge();
      final result = await bridge.withInternalCalls<int>(() async => 42);
      expect(result, 42);
    });
  });

  group('internalGuard', () {
    test('returns a reject CallToolResult when flag is off', () {
      final bridge = ChromeBridge();
      final reject = internalGuard(bridge, 'studio.bundle.install');
      expect(reject, isNotNull);
      expect(reject!.isError, isTrue);
      final text = (reject.content.first as mk.KernelTextContent).text;
      expect(text.contains('"ok":false'), isTrue);
      expect(text.contains('studio.bundle.install'), isTrue);
      expect(text.toLowerCase().contains('internal'), isTrue);
    });

    test('returns null (proceed) when flag is on', () {
      final bridge = ChromeBridge()..internalCallsEnabled = true;
      final proceed = internalGuard(bridge, 'studio.bundle.install');
      expect(proceed, isNull);
    });

    test('proceeds inside withInternalCalls body', () async {
      final bridge = ChromeBridge();
      mk.KernelToolResult? captured;
      await bridge.withInternalCalls(() async {
        captured = internalGuard(bridge, 'studio.chrome.create_package');
        return null;
      });
      expect(captured, isNull);
      // After wrap finishes, the guard rejects again.
      final after = internalGuard(bridge, 'studio.chrome.create_package');
      expect(after, isNotNull);
      expect(after!.isError, isTrue);
    });
  });
}
