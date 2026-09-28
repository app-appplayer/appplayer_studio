/// The studio's BLE wiring, assembled once.
///
/// A process has ONE radio — `UniversalBle.startScan` / `stopScan` are global —
/// so every consumer must go through one owner or they silence each other
/// without knowing it. The studio has several: a bundle observing `ble://scan`,
/// the `provision.candidates` sweep, and the connect path locating a device id.
/// Each used to open a radio of its own, and the `stop` that ended one killed
/// the others' scan. The killed side is never told and still believes its scan
/// is live, so it never restarts: the observation goes quiet for the rest of
/// the session.
///
/// Assembled here rather than re-derived at each consumer, because getting it
/// wrong is silent — the scan simply stops being delivered and nothing reports
/// it.
///
/// That includes the `source=ble` discovery scan: [BleBoardScanner] opens a
/// scan of its own, which is correct for a process with one BLE consumer and
/// wrong for this one. Board discovery is a hub SUBSCRIBER here, and the
/// scanner is left unreferenced so there is no path back to a private scan.
///
/// Matching boards by service UUID against the hub's UNFILTERED scan was the
/// open question — MCP boards carry the 128-bit MCP Serving UUID in the primary
/// advertisement and their name in the scan response, and provisioning matches
/// on the `mcp-prov` NAME precisely because a BLE stack may not surface a
/// 128-bit UUID from an advertisement (see [ProvisioningUuids.advertisedName]).
/// A board's name is free-form, so there is no name branch available here. It
/// was settled by measurement rather than by reasoning from that comment: on
/// macOS, against a real ESP32 advertising both, an unfiltered hub scan carries
/// the 128-bit UUID through and the subscription sights the board.
library;

import 'dart:async';

import 'package:meta/meta.dart' show visibleForTesting;

import 'ble_provisioning/ble_provisioning.dart'
    show ProvisioningCandidate, ProvisioningUuids;
import 'ble_scan/ble_scan.dart'
    show BleAdvertisement, BleScanFilter, BleScanHub, UniversalBleScanRadio;
import 'ble_transport/ble_transport.dart'
    show BleBoardCandidate, BleBoardScanner, BleLocate, mcpBleServiceUuid;

/// The studio's one radio and everything derived from it.
class StudioBleStack {
  StudioBleStack._(this.hub) : locate = _locateVia(hub);

  /// The real radio, multiplexed.
  factory StudioBleStack.real() =>
      StudioBleStack._(BleScanHub(UniversalBleScanRadio()));

  /// For tests / hosts that already hold a hub (e.g. over a fake radio).
  factory StudioBleStack.on(BleScanHub hub) => StudioBleStack._(hub);

  /// The studio's ONE radio multiplexer. Lazy: the radio idles until something
  /// subscribes, and stops when the last subscriber lets go.
  final BleScanHub hub;

  /// Makes a device id known to the radio stack before a connect-by-id, by
  /// WAITING on the observation that already exists instead of scanning.
  final BleLocate locate;

  /// Devices advertising in provisioning mode, seen through [hub].
  ///
  /// Cancelling the returned stream releases this subscriber's claim, which is
  /// what lets the radio stop once nothing else is watching.
  Stream<ProvisioningCandidate> provisioningCandidates() =>
      _provisioningCandidatesVia(hub);

  /// One bounded window of MCP-serving board sightings, for `source=ble`.
  ///
  /// Bounded because the discovery tool reports a window and then answers;
  /// cancelling releases this subscriber's claim on the radio without
  /// disturbing the others.
  Stream<BleBoardCandidate> boardScan({
    Duration timeout = const Duration(seconds: 15),
  }) => _boardScanVia(hub, timeout);
}

/// Process-shared stack — created on first use.
StudioBleStack? _stack;
StudioBleStack get studioBleStack => _stack ??= StudioBleStack.real();

/// Replaces the process-shared stack. For tests: it is what lets a test assert
/// that a consumer took the studio's radio rather than one of its own, which is
/// the difference this whole file exists for and is invisible from the outside.
@visibleForTesting
set studioBleStack(StudioBleStack stack) => _stack = stack;

/// A [BleLocate] backed by [hub].
///
/// The hub ref-counts the physical scan, so this adds a subscriber for the
/// duration of the wait and disturbs no other observation. Not seeing the
/// device inside the budget is not an error here — the connect that follows
/// reports the miss in its own terms.
BleLocate _locateVia(BleScanHub hub) => (deviceId, timeout) async {
  final sub = hub.subscribe(BleScanFilter(deviceIds: <String>[deviceId]));
  try {
    await sub.events.first.timeout(timeout);
  } on Object catch (_) {
    // Same outcome the private scan gave when its timer fired first.
  } finally {
    await sub.cancel();
  }
};

/// A device is provisionable when it advertises the provisioning service UUID
/// **or** its advertised name marks it as one.
///
/// The name branch is load-bearing on macOS / iOS, not a convenience: the
/// firmware puts the 128-bit service UUID in the primary advertisement and the
/// name in the scan response, and CoreBluetooth does not reliably surface a
/// 128-bit UUID from an advertisement. Filtering on the UUID alone finds
/// nothing on a Mac while working fine on Android.
bool isProvisioningAdvertisement(BleAdvertisement ad) =>
    ad.serviceUuids.contains(ProvisioningUuids.serviceUuid.toLowerCase()) ||
    ad.name.toLowerCase().startsWith(ProvisioningUuids.advertisedName);

Stream<BleBoardCandidate> _boardScanVia(
  BleScanHub hub,
  Duration window,
) async* {
  // Declared per subscription, not on the shared scan: another subscriber
  // (provisioning, a bundle) is watching the same radio for something else.
  final sub = hub.subscribe(
    BleScanFilter(serviceUuids: <String>[mcpBleServiceUuid.toLowerCase()]),
  );
  final seen = <String>{};
  // A DEADLINE, not `Stream.timeout`: that one fires on inactivity, and a board
  // re-advertises continuously, so it would never elapse and the window would
  // never close.
  final queue = StreamController<BleBoardCandidate>();
  final deadline = Timer(window, () {
    if (!queue.isClosed) queue.close();
  });
  final ads = sub.events.listen((ad) {
    // A board re-advertises continuously; the window reports it once.
    if (!seen.add(ad.deviceId)) return;
    if (!queue.isClosed) {
      queue.add(
        BleBoardCandidate(
          deviceId: ad.deviceId,
          localName: ad.name,
          rssi: ad.rssi,
        ),
      );
    }
  });
  try {
    yield* queue.stream;
  } finally {
    deadline.cancel();
    await ads.cancel();
    await sub.cancel();
    if (!queue.isClosed) await queue.close();
  }
}

Stream<ProvisioningCandidate> _provisioningCandidatesVia(BleScanHub hub) {
  late final StreamController<ProvisioningCandidate> ctrl;
  StreamSubscription<BleAdvertisement>? ads;
  Future<void> Function()? release;
  ctrl = StreamController<ProvisioningCandidate>(
    onListen: () {
      // Subscribed unfiltered on purpose: the hub ANDs its filter fields, and
      // "service UUID OR name" cannot be said that way. The match is made here
      // instead — the hub already fans every advertisement out to each
      // subscriber, so this costs a predicate, not a scan.
      final sub = hub.subscribe(const BleScanFilter());
      release = sub.cancel;
      ads = sub.events.where(isProvisioningAdvertisement).listen((ad) {
        if (!ctrl.isClosed) {
          ctrl.add(
            ProvisioningCandidate(
              deviceId: ad.deviceId,
              name: ad.name.isEmpty ? ad.deviceId : ad.name,
              rssi: ad.rssi,
            ),
          );
        }
      }, onError: ctrl.addError);
    },
    onCancel: () async {
      await ads?.cancel();
      await release?.call();
    },
  );
  return ctrl.stream;
}
