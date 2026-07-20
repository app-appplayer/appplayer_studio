// VENDORED COPY of the recipe's test — do not hand-edit. Canonical:
//   os/core/brain_kernel/recipes/ble_provisioning/test/provisioning_capability_test.dart
// Re-vendor alongside debug/tool/sync_provisioning_forks.sh runs.
//
import 'dart:async';

import 'package:appplayer_studio/src/base/bridge/ble_provisioning/ble_provisioning.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake GATT session: canned Wi-Fi list, records the credentials written, and
/// emits `connecting` then a preset terminal status when credentials arrive.
class FakeProvisioningLink implements ProvisioningLink {
  FakeProvisioningLink({this.aps = const [], this.outcome});

  final List<WifiAp> aps;
  final ProvisioningStatus? outcome;
  final _status = StreamController<ProvisioningStatus>.broadcast();
  String? sentSsid;
  String? sentPassword;
  bool closed = false;

  @override
  Future<List<WifiAp>> scanWifi() async => aps;

  @override
  Future<ProvisioningStatus> readStatus() async =>
      outcome ?? const ProvisioningStatus(state: ProvisioningState.idle);

  @override
  Future<void> sendCredentials(String ssid, String password) async {
    sentSsid = ssid;
    sentPassword = password;
    _status.add(const ProvisioningStatus(state: ProvisioningState.connecting));
    if (outcome != null) _status.add(outcome!);
  }

  @override
  Stream<ProvisioningStatus> get status => _status.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _status.close();
  }
}

class FakeProvisioningTransport implements ProvisioningTransport {
  FakeProvisioningTransport(this._candidates, this._linkFor);

  final List<ProvisioningCandidate> _candidates;
  final ProvisioningLink Function(String deviceId) _linkFor;
  FakeProvisioningLink? lastOpened;

  @override
  Stream<List<ProvisioningCandidate>> candidates() async* {
    yield _candidates;
  }

  @override
  Future<ProvisioningLink> open(String deviceId) async {
    final link = _linkFor(deviceId) as FakeProvisioningLink;
    lastOpened = link;
    return link;
  }
}

void main() {
  final candidate = const ProvisioningCandidate(
      deviceId: 'dev-1', name: 'mcp-esp32', rssi: -55);

  test('candidatesJson reflects the transport scan (discovery step)', () async {
    final t = FakeProvisioningTransport([candidate], (_) => FakeProvisioningLink());
    final cap = BleProvisioningCapability(t);
    await Future<void>.delayed(Duration.zero); // let the candidate stream land
    final json = cap.candidatesJson();
    expect(json['candidates'], hasLength(1));
    expect((json['candidates'] as List).first,
        {'deviceId': 'dev-1', 'name': 'mcp-esp32', 'rssi': -55});
    await cap.dispose();
  });

  test('wifiScanJson opens the link, returns the device-seen APs, closes', () async {
    final link = FakeProvisioningLink(aps: const [
      WifiAp(ssid: 'home', rssi: -40, secure: true),
      WifiAp(ssid: 'guest', rssi: -70, secure: false),
    ]);
    final t = FakeProvisioningTransport([candidate], (_) => link);
    final cap = BleProvisioningCapability(t);

    final json = await cap.wifiScanJson('dev-1');
    expect(json['deviceId'], 'dev-1');
    expect((json['aps'] as List).map((a) => (a as Map)['ssid']),
        ['home', 'guest']);
    expect(link.closed, isTrue, reason: 'link closed after scan');
    await cap.dispose();
  });

  test('commissionJson writes credentials and returns the join result', () async {
    final link = FakeProvisioningLink(
        outcome: const ProvisioningStatus(
            state: ProvisioningState.connected, ip: '192.168.0.42'));
    final t = FakeProvisioningTransport([candidate], (_) => link);
    final cap = BleProvisioningCapability(t);

    final json = await cap.commissionJson('dev-1', 'home', 's3cret');
    expect(link.sentSsid, 'home');
    expect(link.sentPassword, 's3cret');
    expect(json['state'], 'connected');
    expect(json['ip'], '192.168.0.42');
    expect(link.closed, isTrue);
    await cap.dispose();
  });

  test('commissionJson surfaces a failed join', () async {
    final link = FakeProvisioningLink(
        outcome: const ProvisioningStatus(
            state: ProvisioningState.failed, error: 'bad-password'));
    final t = FakeProvisioningTransport([candidate], (_) => link);
    final cap = BleProvisioningCapability(t);

    final json = await cap.commissionJson('dev-1', 'home', 'wrong');
    expect(json['state'], 'failed');
    expect(json['error'], 'bad-password');
    await cap.dispose();
  });

  test('commissionJson times out when the device never reports terminal', () async {
    final link = FakeProvisioningLink(); // no outcome → never terminal
    final t = FakeProvisioningTransport([candidate], (_) => link);
    final cap = BleProvisioningCapability(t);

    final json = await cap.commissionJson('dev-1', 'home', 'pw',
        timeout: const Duration(milliseconds: 50));
    expect(json['state'], 'failed');
    expect(json['error'], 'timeout');
    await cap.dispose();
  });
}
