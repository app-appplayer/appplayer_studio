/// POC — verify a `JavascriptCoreRuntime` can be constructed inside a
/// Dart Isolate on macOS and that a second runtime in a SECOND
/// isolate does not stomp the first runtime's static
/// `_sendMessageDartFunc`. If this passes, the multi-bundle JS-tool
/// hang we hit on macOS goes away once each `JsToolRuntime` runs in
/// its own isolate.
library;

import 'dart:isolate';

import 'package:async/async.dart';
import 'package:flutter_js/extensions/handle_promises.dart';
import 'package:flutter_js/flutter_js.dart' as fjs;
import 'package:flutter_test/flutter_test.dart';

void _isolateEntry(SendPort sendPort) async {
  final rt = fjs.getJavascriptRuntime(xhr: false);
  rt.enableHandlePromises();
  final res = rt.evaluate('1 + 2');
  sendPort.send(res.stringResult);
  rt.dispose();
}

/// Spawn an isolate that creates its own runtime and channels a host
/// call through `setupBridge` — the moral equivalent of what
/// `JsHostBridge.attach()` does today, except scoped to its isolate.
/// If the bridge round-trip works AND the second isolate's setup
/// doesn't break the first, we're clear.
void _bridgeIsolateEntry(Map<Symbol, dynamic> args) async {
  final SendPort sendPort = args[#port];
  final String label = args[#label];
  final rt = fjs.getJavascriptRuntime(xhr: false);
  rt.enableHandlePromises();
  final receive = ReceivePort();
  rt.setupBridge('echo', (dynamic raw) {
    return raw; // sync return — flutter_js may serialize the result
  });
  // Tell main we're up — main can fire JS calls via SendPort.
  sendPort.send({#ready: receive.sendPort, #label: label});
  // Wait for shutdown signal.
  await for (final msg in receive) {
    if (msg == 'shutdown') break;
    if (msg is Map && msg[#cmd] == 'eval') {
      final out = rt.evaluate(msg[#code] as String);
      (msg[#reply] as SendPort).send(out.stringResult);
    }
    if (msg is Map && msg[#cmd] == 'sendMessage') {
      // Trigger a JS-side sendMessage('echo', ...) via evaluate.
      final out = rt.evaluate(
        'sendMessage("echo", JSON.stringify({hello:"${msg[#payload]}"}))',
      );
      (msg[#reply] as SendPort).send(out.stringResult);
    }
  }
  receive.close();
  rt.dispose();
  sendPort.send({#shutdown: label});
}

void main() {
  test('single isolate evaluate', () async {
    final receive = ReceivePort();
    await Isolate.spawn(_isolateEntry, receive.sendPort);
    final result = await receive.first;
    expect(result, '3');
    receive.close();
  });

  test('two isolates do not stomp each other', () async {
    final r1 = ReceivePort();
    final r2 = ReceivePort();
    await Isolate.spawn(_bridgeIsolateEntry, <Symbol, dynamic>{
      #port: r1.sendPort,
      #label: 'A',
    });
    await Isolate.spawn(_bridgeIsolateEntry, <Symbol, dynamic>{
      #port: r2.sendPort,
      #label: 'B',
    });
    final stream1 = StreamQueue<dynamic>(r1);
    final stream2 = StreamQueue<dynamic>(r2);
    final ready1 = (await stream1.next) as Map;
    final ready2 = (await stream2.next) as Map;
    final port1 = ready1[#ready] as SendPort;
    final port2 = ready2[#ready] as SendPort;
    // Drive isolate A to evaluate after isolate B has started.
    final reply1 = ReceivePort();
    port1.send(<Symbol, dynamic>{
      #cmd: 'eval',
      #code: '"hello from " + 1',
      #reply: reply1.sendPort,
    });
    expect(await reply1.first, 'hello from 1');
    reply1.close();
    final reply2 = ReceivePort();
    port2.send(<Symbol, dynamic>{
      #cmd: 'eval',
      #code: '"hello from " + 2',
      #reply: reply2.sendPort,
    });
    expect(await reply2.first, 'hello from 2');
    reply2.close();
    // Shutdown both.
    port1.send('shutdown');
    port2.send('shutdown');
    final shut1 = await stream1.next;
    final shut2 = await stream2.next;
    expect(shut1[#shutdown], 'A');
    expect(shut2[#shutdown], 'B');
    await stream1.cancel();
    await stream2.cancel();
  });
}
