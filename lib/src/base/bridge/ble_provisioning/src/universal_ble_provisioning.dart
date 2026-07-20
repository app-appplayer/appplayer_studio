// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_provisioning/lib/src/universal_ble_provisioning.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'provisioning_link.dart';
import 'provisioning_models.dart';

/// [ProvisioningTransport] over `universal_ble` — the real radio/GATT. Web
/// degrades where BLE is unavailable.
class UniversalBleProvisioningTransport implements ProvisioningTransport {
  @override
  Stream<List<ProvisioningCandidate>> candidates() {
    final seen = <String, ProvisioningCandidate>{};
    late final StreamController<List<ProvisioningCandidate>> ctrl;
    StreamSubscription<BleDevice>? sub;
    ctrl = StreamController<List<ProvisioningCandidate>>(
      onListen: () async {
        sub = UniversalBle.scanStream
            .where((d) => d.services
                .map((s) => s.toLowerCase())
                .contains(ProvisioningUuids.serviceUuid))
            .listen((d) {
          seen[d.deviceId] = ProvisioningCandidate(
            deviceId: d.deviceId,
            name: d.name ?? d.rawName ?? '',
            rssi: d.rssi ?? 0,
          );
          ctrl.add(seen.values.toList(growable: false));
        });
        await UniversalBle.startScan();
      },
      onCancel: () async {
        await sub?.cancel();
        await UniversalBle.stopScan();
      },
    );
    return ctrl.stream;
  }

  @override
  Future<ProvisioningLink> open(String deviceId) async {
    await UniversalBle.connect(deviceId);
    await UniversalBle.discoverServices(deviceId);
    return UniversalBleProvisioningLink(deviceId);
  }
}

/// A live provisioning GATT session over `universal_ble`. JSON payloads ride
/// the three provisioning characteristics (see [ProvisioningUuids]).
class UniversalBleProvisioningLink implements ProvisioningLink {
  UniversalBleProvisioningLink(this._deviceId);

  final String _deviceId;

  @override
  Future<List<WifiAp>> scanWifi() async {
    final bytes = await UniversalBle.read(_deviceId,
        ProvisioningUuids.serviceUuid, ProvisioningUuids.wifiListChar);
    final obj = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    final aps = (obj['aps'] as List?) ?? const [];
    return [
      for (final a in aps) WifiAp.fromJson(Map<String, Object?>.from(a as Map)),
    ];
  }

  @override
  Future<void> sendCredentials(String ssid, String password) async {
    final payload =
        utf8.encode(jsonEncode({'ssid': ssid, 'password': password}));
    await UniversalBle.write(_deviceId, ProvisioningUuids.serviceUuid,
        ProvisioningUuids.credentialsChar, Uint8List.fromList(payload));
  }

  @override
  Stream<ProvisioningStatus> get status async* {
    await UniversalBle.subscribeNotifications(_deviceId,
        ProvisioningUuids.serviceUuid, ProvisioningUuids.statusChar);
    yield* UniversalBle.characteristicValueStream(
            _deviceId, ProvisioningUuids.statusChar)
        .map((bytes) => ProvisioningStatus.fromJson(
            jsonDecode(utf8.decode(bytes)) as Map<String, Object?>));
  }

  @override
  Future<ProvisioningStatus> readStatus() async {
    final bytes = await UniversalBle.read(_deviceId,
        ProvisioningUuids.serviceUuid, ProvisioningUuids.statusChar);
    return ProvisioningStatus.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, Object?>);
  }

  @override
  Future<void> close() => UniversalBle.disconnect(_deviceId);
}
