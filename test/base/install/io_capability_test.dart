/// `io.connect_device` over the shared io_drivers wiring: the desktop serial
/// driver is a known type (platform spec 11 §5) and a refusal is an ordinary
/// tool error, not an escape from the handler.
library;

import 'dart:convert';

import 'package:appplayer_studio/src/base/install/io_capability.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_io/mcp_io.dart' show IoRuntime;

String _text(mk.KernelToolResult r) =>
    r.content.whereType<mk.KernelTextContent>().map((c) => c.text).join();

void main() {
  late mk.InProcessKernelServerHost host;

  setUp(() {
    host = mk.InProcessKernelServerHost();
    registerIoCapability(
      registry: mk.HostToolRegistry(
        endpoint: host,
        attachToDispatcher: (_, _) {},
        detachFromDispatcher: (_) {},
      ),
    );
  });

  Future<mk.KernelToolResult> connect(
    String type,
    Map<String, dynamic> params,
  ) => host.callTool('io.connect_device', <String, dynamic>{
    'type': type,
    'id': 'dev1',
    'params': params,
  });

  test('an unknown driver type is refused as a tool error', () async {
    final r = await connect('nope', const <String, dynamic>{});
    expect(r.isError, isTrue);
    expect(_text(r), isNot(contains('port')));
  });

  test(
    'serial is a known type: it asks for its port rather than being unknown',
    () async {
      final r = await connect('serial', const <String, dynamic>{});
      expect(r.isError, isTrue);
      final text = _text(r);
      expect(text, contains('params.port'), reason: text);
      expect(jsonDecode(text) is Map, isTrue);
    },
  );

  test(
    'a serial value the driver cannot take is a tool error naming it',
    () async {
      final r = await connect('serial', <String, dynamic>{
        'port': '/dev/ttyUSB0',
        'parity': 'sometimes',
      });
      expect(r.isError, isTrue);
      expect(_text(r), contains('parity'));
    },
  );

  test('the network drivers are still there', () async {
    // http needs a base URI; with none it complains about that, not about an
    // unknown type.
    final r = await connect('http', const <String, dynamic>{});
    final text = _text(r);
    expect(text.toLowerCase(), isNot(contains('unknown')), reason: text);
  });

  test('the host gets the one runtime and may open actions of its own', () {
    IoRuntime? seen;
    registerIoCapability(
      registry: mk.HostToolRegistry(
        endpoint: mk.InProcessKernelServerHost(),
        attachToDispatcher: (_, _) {},
        detachFromDispatcher: (_) {},
      ),
      extraAllowedActions: const <String, List<String>>{
        'serial.write_line': <String>['work'],
      },
      onRuntime: (r) => seen = r,
    );
    expect(seen, isNotNull);
  });
}
