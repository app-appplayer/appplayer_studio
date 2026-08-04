import 'dart:async';

import 'package:appplayer_studio/src/base/bridge/ble_scan/ble_scan.dart';
import 'package:appplayer_studio/src/base/bridge/ble_stack.dart';
import 'package:appplayer_studio/src/base/install/provisioning_capability.dart'
    show provisioningCandidates;
import 'package:appplayer_studio/src/base/runtime/stream_sources.dart'
    show studioBleScanHub;
import 'package:flutter_test/flutter_test.dart';

/// Scripted radio — the studio's single physical scan, replaced with a
/// controllable stream. Records start/stop so the ref-count lifecycle can be
/// asserted: a consumer that stops the radio out from under another consumer is
/// exactly the defect these tests exist for.
class FakeRadio implements BleScanRadio {
  final _controller = StreamController<BleAdvertisement>.broadcast();
  int starts = 0;
  int stops = 0;
  bool get scanning => starts > stops;

  void emit(BleAdvertisement ad) => _controller.add(ad);

  @override
  Stream<BleAdvertisement> get advertisements => _controller.stream;
  @override
  Future<void> start() async => starts++;
  @override
  Future<void> stop() async => stops++;
}

BleAdvertisement _ad(
  String id, {
  String name = '',
  int rssi = -50,
  List<String> uuids = const [],
}) =>
    BleAdvertisement(
      deviceId: id,
      name: name.isEmpty ? id : name,
      rssi: rssi,
      serviceUuids: uuids,
    );

/// The provisioning service UUID as the radio reports it (lowercased).
const String _provUuid = '4d435050-524f-5600-8000-6d6370726f76';

/// The MCP Serving service UUID, likewise.
const String _mcpUuid = '4d435042-4c45-0001-8000-6d6370626c65';

void main() {
  test('the bundle-facing hub IS the stack\'s hub — one owner, not two', () {
    // `ble://scan` and the provisioning / connect paths must land on the same
    // radio. A second hub here would be its own owner, and the two would stop
    // each other's process-global scan without either being told.
    expect(identical(studioBleScanHub, studioBleStack.hub), isTrue);
  });

  group('locate — a WAIT on the shared radio, not a scan of its own', () {
    test('returns when the device is seen, without stopping a live scan',
        () async {
      final radio = FakeRadio();
      final stack = StudioBleStack.on(BleScanHub(radio));

      // Somebody else is already observing (a bundle holding `ble://scan`).
      final observer = stack.hub.subscribe(const BleScanFilter());
      final seen = <String>[];
      observer.events.listen((ad) => seen.add(ad.deviceId));
      await Future<void>.delayed(Duration.zero);
      expect(radio.scanning, isTrue);

      final located = stack.locate('board-1', const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      radio.emit(_ad('board-1'));
      await located;

      // The locate released only its own claim.
      expect(radio.scanning, isTrue, reason: 'the observer still holds it');
      expect(radio.stops, 0);

      // And the observer never went quiet.
      radio.emit(_ad('board-2'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, containsAll(<String>['board-1', 'board-2']));

      await observer.cancel();
    });

    test('a miss is not an error — it returns when the budget elapses',
        () async {
      final radio = FakeRadio();
      final stack = StudioBleStack.on(BleScanHub(radio));

      await stack.locate('never-shows', const Duration(milliseconds: 20));

      // Nothing else was watching, so the radio is released after the wait.
      expect(radio.scanning, isFalse);
    });

    test('releases the radio when it was the only subscriber', () async {
      final radio = FakeRadio();
      final stack = StudioBleStack.on(BleScanHub(radio));

      final located = stack.locate('board-1', const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      expect(radio.scanning, isTrue);
      radio.emit(_ad('board-1'));
      await located;

      expect(radio.scanning, isFalse);
      expect(radio.stops, 1);
    });
  });

  group('board scan — the discovery window is a subscriber too', () {
    test('sights MCP-serving boards by service UUID, once each', () async {
      final radio = FakeRadio();
      final stack = StudioBleStack.on(BleScanHub(radio));

      final got = <String>[];
      final sub = stack
          .boardScan(timeout: const Duration(seconds: 5))
          .listen((c) => got.add(c.deviceId));
      await Future<void>.delayed(Duration.zero);

      radio.emit(_ad('board-1', uuids: <String>[_mcpUuid]));
      // A board re-advertises continuously — reported once per window.
      radio.emit(_ad('board-1', uuids: <String>[_mcpUuid]));
      radio.emit(_ad('someone-else', uuids: <String>['0000180f-0000-1000-8000-00805f9b34fb']));
      await Future<void>.delayed(Duration.zero);

      expect(got, <String>['board-1']);
      await sub.cancel();
    });

    test('the window closes on a DEADLINE, not on inactivity', () async {
      final radio = FakeRadio();
      final stack = StudioBleStack.on(BleScanHub(radio));

      var closed = false;
      final sub = stack
          .boardScan(timeout: const Duration(milliseconds: 30))
          .listen((_) {}, onDone: () => closed = true);

      // Keep advertising the whole time: `Stream.timeout` would never fire
      // here, and the window would never end.
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        radio.emit(_ad('board-$i', uuids: <String>[_mcpUuid]));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(closed, isTrue);
      expect(radio.scanning, isFalse, reason: 'the window released the radio');
      await sub.cancel();
    });

    test('does not stop a scan another consumer is holding', () async {
      final radio = FakeRadio();
      final stack = StudioBleStack.on(BleScanHub(radio));

      final observer = stack.hub.subscribe(const BleScanFilter());
      final seen = <String>[];
      observer.events.listen((ad) => seen.add(ad.deviceId));

      final sub = stack.boardScan(timeout: const Duration(seconds: 5)).listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(radio.starts, 1, reason: 'one physical scan, not two');
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(radio.scanning, isTrue);
      radio.emit(_ad('still-here'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains('still-here'));

      await observer.cancel();
    });
  });

  group('provisioning candidates — a subscriber, not a second radio owner', () {
    test('matches by service UUID or by the mcp-prov name', () async {
      final radio = FakeRadio();
      final stack = StudioBleStack.on(BleScanHub(radio));

      final got = <String>[];
      final sub = stack.provisioningCandidates().listen((c) => got.add(c.deviceId));
      await Future<void>.delayed(Duration.zero);

      radio.emit(_ad('by-uuid', uuids: <String>[_provUuid]));
      // The macOS path: no 128-bit UUID surfaces, the name carries the match.
      radio.emit(_ad('by-name', name: 'mcp-prov-a1b2'));
      radio.emit(_ad('unrelated', name: 'someone-elses-beacon'));
      await Future<void>.delayed(Duration.zero);

      expect(got, <String>['by-uuid', 'by-name']);
      await sub.cancel();
    });

    test('cancelling releases only its own claim on the radio', () async {
      final radio = FakeRadio();
      final stack = StudioBleStack.on(BleScanHub(radio));

      final observer = stack.hub.subscribe(const BleScanFilter());
      final seen = <String>[];
      observer.events.listen((ad) => seen.add(ad.deviceId));

      final sub = stack.provisioningCandidates().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(radio.starts, 1, reason: 'one physical scan, not two');

      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      // THE defect this wiring exists for: the provisioning window closing used
      // to stop the process-global scan, silencing the observer for good.
      expect(radio.scanning, isTrue);
      radio.emit(_ad('still-here'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains('still-here'));

      await observer.cancel();
      expect(radio.scanning, isFalse);
    });

    test('provision.candidates reports one entry per device over its window',
        () async {
      final radio = FakeRadio();
      final stack = StudioBleStack.on(BleScanHub(radio));

      final result = provisioningCandidates(
        observe: stack.provisioningCandidates,
        window: const Duration(milliseconds: 40),
      );
      await Future<void>.delayed(Duration.zero);
      // A device re-advertises continuously; the tool reports it once.
      radio.emit(_ad('prov-1', name: 'mcp-prov-1', rssi: -70));
      radio.emit(_ad('prov-1', name: 'mcp-prov-1', rssi: -55));
      radio.emit(_ad('prov-2', uuids: <String>[_provUuid]));

      final candidates =
          (await result)['candidates'] as List<Map<String, Object?>>;
      expect(candidates.map((c) => c['deviceId']),
          <String>['prov-1', 'prov-2']);
      // Last sighting wins, so the reported RSSI is the freshest one.
      expect(candidates.first['rssi'], -55);
      // The window released the radio on its way out.
      expect(radio.scanning, isFalse);
    });
  });
}
