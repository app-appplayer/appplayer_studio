import 'dart:async';

import 'package:appplayer_studio/src/base/bridge/ble_scan/ble_scan.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRadio implements BleScanRadio {
  final _c = StreamController<BleAdvertisement>.broadcast();
  int starts = 0, stops = 0;
  void emit(BleAdvertisement ad) => _c.add(ad);
  @override
  Stream<BleAdvertisement> get advertisements => _c.stream;
  @override
  Future<void> start() async => starts++;
  @override
  Future<void> stop() async => stops++;
}

BleAdvertisement _ad(String id, int rssi, {List<String> uuids = const []}) =>
    BleAdvertisement(deviceId: id, name: id, rssi: rssi, serviceUuids: uuids);

void main() {
  test('start → buffer matching ads → poll returns the window (newest first)',
      () async {
    final radio = FakeRadio();
    final cap = BleScanCapability(BleScanHub(radio));

    final started = cap.startJson({'minRssi': -60});
    final id = started['subscriptionId'] as String;

    radio.emit(_ad('a', -50));
    radio.emit(_ad('b', -80)); // filtered out (weak)
    radio.emit(_ad('c', -40));
    await Future<void>.delayed(Duration.zero);

    final polled = cap.pollJson(id);
    final ads = (polled['advertisements'] as List).cast<Map>();
    expect(ads.map((a) => a['deviceId']), ['c', 'a'], reason: 'newest first');

    await cap.dispose();
  });

  test('latest-per-device: a re-advertising device keeps one slot with fresh rssi',
      () async {
    final radio = FakeRadio();
    final cap = BleScanCapability(BleScanHub(radio));
    final id = cap.startJson(const {})['subscriptionId'] as String;

    radio.emit(_ad('x', -70));
    radio.emit(_ad('x', -55)); // same device, stronger
    await Future<void>.delayed(Duration.zero);

    final ads = (cap.pollJson(id)['advertisements'] as List).cast<Map>();
    expect(ads, hasLength(1));
    expect(ads.single['rssi'], -55);
    await cap.dispose();
  });

  test('two subscriptions = two independent windows (multiplex over one radio)',
      () async {
    final radio = FakeRadio();
    final cap = BleScanCapability(BleScanHub(radio));
    final beacons =
        cap.startJson({'serviceUuids': ['abcd']})['subscriptionId'] as String;
    final all = cap.startJson(const {})['subscriptionId'] as String;

    radio.emit(_ad('beacon', -50, uuids: ['abcd']));
    radio.emit(_ad('phone', -50));
    await Future<void>.delayed(Duration.zero);

    expect(radio.starts, 1, reason: 'one physical radio for both');
    final beaconAds = (cap.pollJson(beacons)['advertisements'] as List);
    final allAds = (cap.pollJson(all)['advertisements'] as List);
    expect(beaconAds.map((a) => (a as Map)['deviceId']), ['beacon']);
    expect((allAds).map((a) => (a as Map)['deviceId']).toSet(),
        {'beacon', 'phone'});

    // list reflects both, with their filters
    final list = cap.listJson();
    expect((list['subscriptions'] as List), hasLength(2));
    expect(list['scanning'], isTrue);

    await cap.dispose();
  });

  test('stop cancels the subscription and (last one) stops the radio', () async {
    final radio = FakeRadio();
    final cap = BleScanCapability(BleScanHub(radio));
    final id = cap.startJson(const {})['subscriptionId'] as String;
    expect((await cap.stopJson(id))['stopped'], isTrue);
    expect(radio.stops, 1);
    expect((cap.pollJson(id))['error'], isNotNull);
    expect((await cap.stopJson(id))['stopped'], isFalse); // idempotent
  });
}
