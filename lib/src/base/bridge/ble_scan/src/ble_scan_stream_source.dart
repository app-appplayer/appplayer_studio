// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_scan/lib/src/ble_scan_stream_source.dart
// Regenerate with debug/tool/sync_ble_scan_fork.sh.
//
import 'dart:async';

import 'ble_advertisement.dart';
import 'ble_scan_hub.dart';

/// Bridges [BleScanHub] to a runtime `registerStreamSource` seam so a
/// `client.mcpStream` channel can observe advertisements live.
///
/// A bundle declares a channel with `uri: "ble://scan"` and `params` = a scan
/// filter; the host registers this source for the `ble` scheme
/// (`runtime.registerStreamSource('ble', source.open)`). Each channel gets its
/// OWN hub subscription with its OWN filter — the multiplex the hub provides —
/// and every matching advertisement is pushed as a JSON map (the
/// [BleAdvertisement.toJson] shape the poll tool already emits). Cancelling the
/// channel (`channel.stop` / listener cancel) cancels the hub subscription and
/// decrements the shared radio's ref-count.
class BleScanStreamSource {
  BleScanStreamSource(this._hub);

  final BleScanHub _hub;

  /// The `open` callback to hand to `registerStreamSource('ble', open)`.
  Stream<Map<String, Object?>> open(String uri, Map<String, dynamic> params) {
    final filter = BleScanFilter.fromJson(Map<String, Object?>.from(params));
    late final StreamController<Map<String, Object?>> ctrl;
    BleScanSubscription? sub;
    StreamSubscription<BleAdvertisement>? inner;
    ctrl = StreamController<Map<String, Object?>>(
      onListen: () {
        sub = _hub.subscribe(filter);
        inner = sub!.events.listen((ad) => ctrl.add(ad.toJson()));
      },
      onCancel: () async {
        await inner?.cancel();
        await sub?.cancel();
      },
    );
    return ctrl.stream;
  }
}
