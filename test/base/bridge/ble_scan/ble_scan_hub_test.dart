import 'dart:async';

import 'package:appplayer_studio/src/base/bridge/ble_scan/ble_scan.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted radio — the hub's single physical scan, replaced with a controllable
/// stream. Records start/stop so the ref-count lifecycle can be asserted.
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

BleAdvertisement _ad(String id,
        {int rssi = -50, List<String> uuids = const []}) =>
    BleAdvertisement(deviceId: id, name: id, rssi: rssi, serviceUuids: uuids);

void main() {
  group('BleScanHub — one radio multiplexed across many subscriptions', () {
    test('each subscription gets ONLY its own filter\'s matches (isolation)',
        () async {
      final radio = FakeRadio();
      final hub = BleScanHub(radio);

      // App A: beacons advertising service "abcd". App B: strong signals only.
      final a = hub.subscribe(const BleScanFilter(serviceUuids: ['ABCD']));
      final b = hub.subscribe(const BleScanFilter(minRssi: -60));
      final aSeen = <String>[], bSeen = <String>[];
      a.events.listen((ad) => aSeen.add(ad.deviceId));
      b.events.listen((ad) => bSeen.add(ad.deviceId));

      radio.emit(_ad('beacon', rssi: -80, uuids: ['abcd'])); // A only (weak)
      radio.emit(_ad('phone', rssi: -40)); // B only (no uuid, strong)
      radio.emit(_ad('tag', rssi: -30, uuids: ['abcd'])); // A and B
      await Future<void>.delayed(Duration.zero);

      expect(aSeen, ['beacon', 'tag']);
      expect(bSeen, ['phone', 'tag']);

      await hub.dispose();
    });

    test('one physical radio for N subscriptions (not one per subscriber)',
        () async {
      final radio = FakeRadio();
      final hub = BleScanHub(radio);
      hub.subscribe(const BleScanFilter());
      hub.subscribe(const BleScanFilter());
      hub.subscribe(const BleScanFilter());
      await Future<void>.delayed(Duration.zero);
      expect(radio.starts, 1, reason: 'radio started once for three subs');
      expect(hub.subscriptionIds, hasLength(3));
      await hub.dispose();
    });

    test('ref-counted radio: scans while ≥1 sub, stops on the last cancel',
        () async {
      final radio = FakeRadio();
      final hub = BleScanHub(radio);
      final a = hub.subscribe(const BleScanFilter());
      final b = hub.subscribe(const BleScanFilter());
      await Future<void>.delayed(Duration.zero);
      expect(radio.scanning, isTrue);

      await a.cancel();
      expect(radio.scanning, isTrue, reason: 'b still open → keep scanning');
      expect(radio.stops, 0);

      await b.cancel();
      expect(radio.scanning, isFalse, reason: 'last sub gone → stop');
      expect(radio.stops, 1);
    });

    test('a re-subscribe after the radio stopped restarts it', () async {
      final radio = FakeRadio();
      final hub = BleScanHub(radio);
      final a = hub.subscribe(const BleScanFilter());
      await Future<void>.delayed(Duration.zero);
      await a.cancel();
      expect(radio.scanning, isFalse);

      hub.subscribe(const BleScanFilter());
      await Future<void>.delayed(Duration.zero);
      expect(radio.starts, 2, reason: 'restarted for the new subscriber');
      expect(radio.scanning, isTrue);
      await hub.dispose();
    });

    test('cancelling one subscription does not disturb the others', () async {
      final radio = FakeRadio();
      final hub = BleScanHub(radio);
      final a = hub.subscribe(const BleScanFilter());
      final b = hub.subscribe(const BleScanFilter());
      final bSeen = <String>[];
      b.events.listen((ad) => bSeen.add(ad.deviceId));

      await a.cancel();
      radio.emit(_ad('x'));
      await Future<void>.delayed(Duration.zero);

      expect(bSeen, ['x'], reason: 'b keeps receiving after a is cancelled');
      await hub.dispose();
    });

    test('cancelById mirrors the tool-surface stop path', () async {
      final radio = FakeRadio();
      final hub = BleScanHub(radio);
      final a = hub.subscribe(const BleScanFilter());
      expect(hub.subscriptionIds, contains(a.id));
      await hub.cancelById(a.id);
      expect(hub.subscriptionIds, isEmpty);
      expect(radio.scanning, isFalse);
    });
  });

  group('BleScanFilter', () {
    test('empty filter matches every advertisement', () {
      expect(const BleScanFilter().matches(_ad('any')), isTrue);
    });
    test('constraints are ANDed; service uuid match is case-insensitive', () {
      const f = BleScanFilter(serviceUuids: ['ABCD'], minRssi: -60);
      expect(f.matches(_ad('a', rssi: -50, uuids: ['abcd'])), isTrue);
      expect(f.matches(_ad('a', rssi: -70, uuids: ['abcd'])), isFalse); // rssi
      expect(f.matches(_ad('a', rssi: -50, uuids: ['ffff'])), isFalse); // uuid
    });
  });
}
