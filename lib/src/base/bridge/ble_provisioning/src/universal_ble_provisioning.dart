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
  UniversalBleProvisioningTransport({this.observe});

  /// Where provisioning advertisements come from.
  ///
  /// Null is allowed only because [open] needs none — a GATT session is not a
  /// scan, and the commission path builds this transport for that alone.
  /// [candidates] without it REFUSES.
  ///
  /// It used to fall back to driving the radio itself, and that default is
  /// gone: `UniversalBle.startScan` / `stopScan` are PROCESS-GLOBAL, so the
  /// stop ending a provisioning scan silenced whatever else was scanning (the
  /// discovery axis, a bundle's `ble://scan`) — and that owner is never told,
  /// still believes its scan is live, and so never restarts it. The
  /// observation just goes quiet and stays quiet.
  ///
  /// Refusing is the honest answer: this recipe has no way to observe without
  /// taking a radio it does not own.
  final Stream<ProvisioningCandidate> Function()? observe;

  @override
  Stream<List<ProvisioningCandidate>> candidates() {
    final source = observe;
    if (source == null) {
      throw StateError(
        'no observation wired: pass `observe` so candidates come from the '
        "host's radio — this transport will not start a scan of its own",
      );
    }
    return _accumulate(source());
  }

  /// A growing, device-deduped snapshot — the contract both sources deliver.
  Stream<List<ProvisioningCandidate>> _accumulate(
    Stream<ProvisioningCandidate> ads,
  ) {
    final seen = <String, ProvisioningCandidate>{};
    return ads.map((c) {
      seen[c.deviceId] = c;
      return seen.values.toList(growable: false);
    });
  }

  @override
  Future<ProvisioningLink> open(String deviceId) async {
    await UniversalBle.connect(deviceId);
    await UniversalBle.discoverServices(deviceId);
    // A notification carries at most `MTU - 3` bytes and CANNOT continue like
    // a read can, so on Android's default MTU of 23 the status JSON is cut at
    // 20 bytes. `{"state":"idle"}` is 16 and arrives whole; `{"state":
    // "connecting"}` is 22 and arrives as `{"state":"connecting` — the session
    // died on `FormatException: Unterminated string` exactly when provisioning
    // started working. Ask for room; a peer that refuses just keeps the
    // default and [UniversalBleProvisioningLink.status] still recovers by
    // reading.
    try {
      await UniversalBle.requestMtu(deviceId, _preferredMtu);
    } catch (_) {
      // Not fatal and not universally supported (iOS/macOS negotiate on their
      // own and have no API for it).
    }
    return UniversalBleProvisioningLink(deviceId);
  }

  /// Comfortably above any status or credential payload, and within what an
  /// ESP32 NimBLE peer accepts.
  static const int _preferredMtu = 247;
}

/// Decodes a status notification payload, or null when it is not a complete
/// JSON object.
///
/// Incompleteness is the expected case, not a corruption: a notification is
/// capped at `MTU - 3` bytes and, unlike a read, has no continuation. The
/// caller answers null with a full read.
ProvisioningStatus? decodeStatusPayload(Uint8List bytes) {
  try {
    return ProvisioningStatus.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, Object?>);
  } on FormatException {
    return null;
  } on TypeError {
    // Truncation can also land on a fragment that parses as a non-object.
    return null;
  }
}

/// A live provisioning GATT session over `universal_ble`. JSON payloads ride
/// the three provisioning characteristics (see [ProvisioningUuids]).
class UniversalBleProvisioningLink implements ProvisioningLink {
  UniversalBleProvisioningLink(this._deviceId);

  final String _deviceId;

  @override
  Future<List<WifiAp>> scanWifi() => pageWifiList(
        read: () async {
          final bytes = await UniversalBle.read(_deviceId,
              ProvisioningUuids.serviceUuid, ProvisioningUuids.wifiListChar);
          return jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
        },
        seek: (from) => UniversalBle.write(
          _deviceId,
          ProvisioningUuids.serviceUuid,
          ProvisioningUuids.wifiListChar,
          Uint8List.fromList(utf8.encode(jsonEncode({'from': from}))),
        ),
      );

  @override
  Future<void> sendCredentials(String ssid, String password) async {
    final payload =
        utf8.encode(jsonEncode({'ssid': ssid, 'password': password}));
    await UniversalBle.write(_deviceId, ProvisioningUuids.serviceUuid,
        ProvisioningUuids.credentialsChar, Uint8List.fromList(payload));
  }

  /// Status updates.
  ///
  /// A notification is treated as "something changed", not as the whole
  /// message. Its payload is capped at `MTU - 3` with no continuation, so a
  /// status longer than that arrives truncated and cannot be parsed. A READ of
  /// the same characteristic continues over as many ATT Read Blob requests as
  /// the value needs, so it is the reliable way to get the full value at any
  /// MTU. The fast path still uses the payload when it parses — that keeps
  /// short-lived intermediate states that a follow-up read could miss — and
  /// falls back to a read only when it does not.
  @override
  Stream<ProvisioningStatus> get status async* {
    await UniversalBle.subscribeNotifications(_deviceId,
        ProvisioningUuids.serviceUuid, ProvisioningUuids.statusChar);
    final stream = UniversalBle.characteristicValueStream(
        _deviceId, ProvisioningUuids.statusChar);
    await for (final bytes in stream) {
      yield decodeStatusPayload(bytes) ?? await readStatus();
    }
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
