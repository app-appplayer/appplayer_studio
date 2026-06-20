import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

/// JsToolRuntime now runs inside a worker isolate (see js_tool_isolate.dart).
/// Direct `evaluate()` from flutter_tester hangs waiting on the worker's
/// init handshake because the test environment doesn't drive isolate
/// I/O the way the live host does. The production path is covered by
/// `js_dispatch_test.dart` (HostBundleActivationContext kind:js
/// dispatch); these direct-runtime tests stay as `skip:` so the surface
/// shape is documented without blocking the suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'JsToolRuntime',
    skip:
        'isolate-based runtime cannot complete handshake under flutter_tester '
        '— production path covered by js_dispatch_test.',
    () {
      test('evaluates a synchronous expression', () async {
        final rt = JsToolRuntime();
        final result = await rt.evaluate('1 + 2');
        expect(result.stringResult, '3');
        expect(result.isError, isFalse);
      });

      test('defines and calls a function', () async {
        final rt = JsToolRuntime();
        await rt.evaluate('function shout(s) { return s.toUpperCase(); }');
        final result = await rt.evaluate('shout("hi")');
        expect(result.stringResult, 'HI');
      });

      test('reports JS errors via isError', () async {
        final rt = JsToolRuntime();
        final result = await rt.evaluate('throw new Error("nope")');
        expect(result.isError, isTrue);
      });

      test('isolates per-instance globals', () async {
        final a = JsToolRuntime();
        final b = JsToolRuntime();
        await a.evaluate('var marker = "A";');
        final fromB = await b.evaluate('typeof marker');
        expect(fromB.stringResult, 'undefined');
      });

      test('evaluates a Promise via evaluateAsync', () async {
        final rt = JsToolRuntime();
        final result = await rt.evaluateAsync('Promise.resolve(40 + 2)');
        // handlePromise wraps the resolved value through JSON.stringify
        // before handing it back, so a JS number 42 arrives as the
        // string `'42'` (a JSON literal, not a quoted string).
        expect(result.stringResult, '42');
      });

      test('evaluateAsync returns object literals as JSON', () async {
        final rt = JsToolRuntime();
        final result = await rt.evaluateAsync(
          'Promise.resolve({a: 1, b: "two"})',
        );
        expect(result.stringResult, '{"a":1,"b":"two"}');
      });
    },
  );
}
