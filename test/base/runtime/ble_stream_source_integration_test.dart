/// Integration: the studio's `client.mcpStream` `ble://scan` wiring, end to end
/// through a real render runtime. A bundle's channel (the canonical
/// `buildBleScanLiveMonitorUi` page) is resolved by [registerStudioStreamSources]
/// to a [BleScanStreamSource] over a FAKE radio, so advertisements pushed by the
/// radio flow channel → hub → `onMessage` (append) → runtime state exactly as a
/// live ESP32 feed would — deterministically, no hardware.
@TestOn('vm')
library;

import 'dart:async';

import 'package:appplayer_studio/base.dart' show registerStudioStreamSources;
import 'package:appplayer_studio/runtime.dart';
import 'package:appplayer_studio/src/base/bridge/ble_scan/ble_scan.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRadio implements BleScanRadio {
  final _c = StreamController<BleAdvertisement>.broadcast();
  void emit(BleAdvertisement ad) => _c.add(ad);
  Future<void> close() => _c.close();
  @override
  Stream<BleAdvertisement> get advertisements => _c.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets(
      'ble://scan advertisements reach runtime state through the studio wiring',
      (tester) async {
    final radio = _FakeRadio();
    final runtime = MCPUIRuntime();
    List<dynamic>? ads;

    // Everything runs in a real zone: `initialize` never settles under
    // fake-async, and the channel keeps a live stream subscription, so all
    // start/emit/drain/teardown must complete before the widget test's
    // pending-timer check at teardown.
    await tester.runAsync(() async {
      await runtime.initialize(buildBleScanLiveMonitorUi());
      // The wiring under test: exactly what dsl_workspace_view calls on every
      // render runtime, but over an injected fake-radio hub.
      registerStudioStreamSources(runtime, bleScanHub: BleScanHub(radio));

      // The bundle's Start button dispatches `channel.start` for this channel.
      await runtime.channelManager!.startChannel('advertisements');

      radio.emit(const BleAdvertisement(
          deviceId: 'esp32-01', name: 'ESP32 Sensor', rssi: -48));
      radio.emit(const BleAdvertisement(
          deviceId: 'beacon-02', name: 'Beacon', rssi: -71));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      ads = runtime.stateManager.get<List<dynamic>>('advertisements');

      await runtime.channelManager!.stopChannel('advertisements');
      await radio.close();
      runtime.destroy();
    });

    expect(ads, isNotNull);
    expect(ads, hasLength(2),
        reason: 'both pushed advertisements must append to state');
    expect((ads!.first as Map)['name'], 'ESP32 Sensor');
    expect((ads!.first as Map)['rssi'], -48);
    expect((ads!.last as Map)['deviceId'], 'beacon-02');
  });
}
