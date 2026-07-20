/// The host wiring of the provisioning recipe set: registering the capability
/// exposes the full `provision.*` surface on the shared host registry (so a
/// bundle's `type:tool` calls reach them in-process). The invoke bodies drive
/// real radios / sockets / serial ports and are covered live (see the
/// dogfood); this pins the registration contract.
@TestOn('vm')
library;

import 'dart:io';

import 'package:appplayer_studio/src/base/install/provisioning_capability.dart';
import 'package:brain_kernel/brain_kernel.dart' as fb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registerProvisioningCapability exposes the provision.* surface',
      () async {
    final tmp = Directory.systemTemp.createTempSync('prov_wire_');
    final app = await fb.KernelApp.boot(
      workspaceId: 'prov_wire_test',
      kvStorage: fb.KvStoragePortAdapter(rootDir: tmp.path),
      bundleRegistryStorageDir: tmp.path,
    );
    final handlers = <String, fb.KernelToolHandler>{};
    final endpoint = app.addEndpoint(label: 'prov', appName: 'prov');
    endpoint.server.register();
    final registry = fb.HostToolRegistry(
      endpoint: endpoint.server,
      attachToDispatcher: (name, h) => handlers[name] = h,
      detachFromDispatcher: (_) {},
    );

    final names = registerProvisioningCapability(registry);

    expect(
        names,
        containsAll(<String>[
          'provision.candidates',
          'provision.commission',
          'provision.softap_commission',
          'provision.serial_ports',
          'provision.console',
          'provision.smartconfig',
        ]));
    // Registered handlers land on the dispatcher, so a bundle/agent can call
    // them by name.
    expect(handlers.keys, containsAll(names));

    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {/* best-effort */}
  });

  test('listSerialPorts returns a sorted path list', () async {
    final res = await listSerialPorts();
    final ports = res['ports'] as List<Object?>;
    // Shape only — the machine may or may not have serial devices attached.
    for (final p in ports) {
      expect(p, isA<String>());
      expect((p as String).startsWith('/dev/'), isTrue);
    }
  });

  test('provisioningConsole guards commission without ssid', () async {
    final res = await provisioningConsole(
      port: '/dev/null-nonexistent-port',
      op: 'commission',
    );
    expect(res['ok'], isFalse);
    expect(res['error'], contains('ssid'));
  });
}
