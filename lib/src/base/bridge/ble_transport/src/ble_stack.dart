// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_transport/lib/src/ble_stack.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
/// The host's BLE wiring, assembled once.
///
/// There is ONE radio in a process — `UniversalBle.startScan` / `stopScan` are
/// global — so every consumer has to go through one owner or they silence each
/// other without knowing. This bundles that owner ([hub]) together with the two
/// things the rest of the graph needs from it: how a Stage-1 scan is observed
/// ([boardScan]) and how a device id is located before a connect ([locate]).
///
/// Assembled here rather than repeated in each tier's composition root: a shell
/// that reuses these adapters (AppPlayer X) must not have to re-derive the
/// wiring, because getting it wrong is silent — the scan simply stops being
/// delivered and nothing reports it.
library;

import 'dart:async';

import '../../ble_scan/ble_scan.dart'
    show BleAdvertisement, BleScanFilter, BleScanHub, UniversalBleScanRadio;
import 'package:mcp_client/mcp_client.dart' show ClientTransport;

import 'ble_board_scanner.dart' show BleBoardCandidate;
import 'ble_client_transport.dart';
import 'ble_link.dart' show BleLocate;
import 'ble_uuids.dart' show mcpBleServiceUuid;
import 'universal_ble_link.dart';

class BleStack {
  BleStack._(this.hub) : locate = bleLocateVia(hub);

  /// The host's ONE radio multiplexer.
  factory BleStack.real() => BleStack._(BleScanHub(UniversalBleScanRadio()));

  /// Visible for tests / shells that already hold a hub.
  factory BleStack.on(BleScanHub hub) => BleStack._(hub);

  final BleScanHub hub;

  /// Waits on [hub] for a device id instead of running a scan of its own.
  final BleLocate locate;

  /// Stage 1 for the `bt` discovery transport — one window of board sightings.
  Stream<BleBoardCandidate> boardScan() => hubBoardCandidates(hub);

  /// A started BLE transport whose link locates through [hub].
  Future<ClientTransport> buildTransport(String deviceId) async {
    final transport = BleClientTransport(
      link: UniversalBleLink(deviceId: deviceId, locate: locate),
    );
    await transport.start();
    return transport;
  }
}

/// Making a device id known to the radio stack — by WATCHING, not by scanning.
///
/// A radio only knows peripherals it has seen advertise, so opening a saved
/// board straight from the launcher fails its first connect-by-id until the
/// device is in the stack's registry. `UniversalBleLink` filled that gap with a
/// scan of its own — and `UniversalBle.startScan` / `stopScan` are
/// process-global, so the stop that ended it silenced whatever else was
/// watching (the discovery axis, a bundle holding `ble://scan`). Those owners
/// are never told and still believe their scan is live, so they never restart:
/// opening one board went quiet for the rest of the session.
///
/// Through the hub it is a wait on the observation that already exists.

/// A [BleLocate] backed by [hub] — the host's ONE radio.
///
/// The hub ref-counts the physical scan, so this adds a subscriber for the
/// duration of the wait and nothing else's observation is disturbed. If the
/// device is not seen within the budget it returns anyway: a miss is not an
/// error here, and the connect that follows reports it in its own terms.
BleLocate bleLocateVia(BleScanHub hub) => (deviceId, timeout) async {
      final sub = hub.subscribe(BleScanFilter(deviceIds: <String>[deviceId]));
      try {
        await sub.events.first.timeout(timeout);
      } on Object catch (_) {
        // Not seen in the budget — same outcome the private scan gave when its
        // timer fired first.
      } finally {
        await sub.cancel();
      }
    };

/// Stage-1 BLE board scan, sourced from the host's shared radio.
///
/// `BleBoardScanner` (the recipe default) calls `startScan` itself. That is
/// correct for a process with one BLE consumer and wrong for this host, which
/// has several: discovery, Wi-Fi onboarding, and any bundle observing
/// `ble://scan`. A BLE adapter serves ONE physical scan — a second one starves
/// the first, measured here as a Discovered tab that showed either the
/// onboarding candidate or the discovered servers but never both.
///
/// So Stage 1 becomes a *subscription* on the shared [BleScanHub] instead of a
/// scan of its own. The hub keeps the single physical scan alive while anyone
/// is listening and fans every advertisement out to each subscriber's own
/// filter. Cost per advertisement is O(subscribers) — a handful — not O(devices),
/// so a room with hundreds of advertising devices costs the same per device as
/// a room with one.
///
/// The window is bounded because `ProbeConfirmingDiscoveryTransport` expects a
/// finite Stage-1 stream per rescan cycle; cancelling it releases this
/// subscriber's claim on the radio without disturbing the others.
Stream<BleBoardCandidate> hubBoardCandidates(
  BleScanHub hub, {
  Duration window = const Duration(seconds: 10),
}) async* {
  // The hub filters per subscription, so the MCP service UUID constraint is
  // declared here rather than applied to the shared scan — another subscriber
  // (onboarding) declares a different one against the same radio.
  final sub = hub.subscribe(
    BleScanFilter(serviceUuids: <String>[mcpBleServiceUuid.toLowerCase()]),
  );
  final seen = <String>{};
  // A DEADLINE, not `Stream.timeout`: that one fires on inactivity, and a scan
  // sees advertisements continuously, so it would never elapse and Stage 1
  // would never finish. The window has to be wall-clock.
  final deadline = Completer<void>();
  final timer = Timer(window, () {
    if (!deadline.isCompleted) deadline.complete();
  });
  final queue = StreamController<BleBoardCandidate>();
  final adSub = sub.events.listen((ad) {
    // A board re-advertises continuously; Stage 1 wants each candidate once per
    // window so the probe stage is not asked to confirm the same device again.
    if (!seen.add(ad.deviceId)) return;
    if (!queue.isClosed) queue.add(_toCandidate(ad));
  });
  unawaited(
    deadline.future.then((_) {
      if (!queue.isClosed) queue.close();
    }),
  );
  try {
    yield* queue.stream;
  } finally {
    timer.cancel();
    await adSub.cancel();
    await sub.cancel();
    if (!queue.isClosed) await queue.close();
  }
}

BleBoardCandidate _toCandidate(BleAdvertisement ad) =>
    BleBoardCandidate(deviceId: ad.deviceId, localName: ad.name, rssi: ad.rssi);
