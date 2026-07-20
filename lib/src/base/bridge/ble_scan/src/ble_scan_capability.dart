// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_scan/lib/src/ble_scan_capability.dart
// Regenerate with debug/tool/sync_ble_scan_fork.sh.
//
import 'dart:async';

import 'ble_advertisement.dart';
import 'ble_scan_hub.dart';

/// JSON-in / JSON-out surface over [BleScanHub] — the single contract both an
/// AGENT (via an MCP tool binding) and a BUNDLE APP (via the runtime tool
/// executor + a polling DSL) drive, with no logic in either consumer.
///
/// Streaming to a request/response tool surface is a **buffer + poll**: each
/// subscription accumulates its matching advertisements into a bounded ring
/// (latest-wins, keyed by deviceId so a live device occupies one slot with its
/// freshest RSSI), and `ble.scan.poll` returns that window — a chart binds its
/// state to the polled list and a timer re-polls. Many subscriptions coexist,
/// each with its own filter and its own window (the multiplex from the hub).
class BleScanCapability {
  BleScanCapability(this._hub, {this.bufferSize = 200});

  final BleScanHub _hub;

  /// Max distinct devices retained per subscription window.
  final int bufferSize;

  final Map<String, _Buffered> _buffers = {};

  /// `ble.scan.start` — register a subscription with its own filter; returns its
  /// id. Begins buffering matching advertisements immediately.
  Map<String, Object?> startJson(Map<String, Object?> filterJson) {
    final sub = _hub.subscribe(BleScanFilter.fromJson(filterJson));
    final buf = _Buffered(sub);
    _buffers[sub.id] = buf;
    buf.streamSub = sub.events.listen((ad) => buf.add(ad, bufferSize));
    return {'subscriptionId': sub.id, 'filter': filterJson};
  }

  /// `ble.scan.poll` — the current advertisement window for [subscriptionId]
  /// (newest first). Non-destructive so a chart can re-read each tick.
  Map<String, Object?> pollJson(String subscriptionId) {
    final buf = _buffers[subscriptionId];
    if (buf == null) {
      return {'error': 'unknown subscription: $subscriptionId'};
    }
    return {
      'subscriptionId': subscriptionId,
      'advertisements': [for (final ad in buf.window()) ad.toJson()],
    };
  }

  /// `ble.scan.stop` — cancel a subscription (ref-counts the shared radio down).
  Future<Map<String, Object?>> stopJson(String subscriptionId) async {
    final buf = _buffers.remove(subscriptionId);
    if (buf == null) return {'stopped': false};
    await buf.streamSub?.cancel();
    await buf.sub.cancel();
    return {'stopped': true};
  }

  /// `ble.scan.list` — live subscriptions, their filters and window sizes.
  Map<String, Object?> listJson() => {
        'subscriptions': [
          for (final e in _buffers.entries)
            {
              'subscriptionId': e.key,
              'filter': {
                'serviceUuids': e.value.sub.filter.serviceUuids,
                'deviceIds': e.value.sub.filter.deviceIds,
                if (e.value.sub.filter.minRssi != null)
                  'minRssi': e.value.sub.filter.minRssi,
              },
              'count': e.value.count,
            }
        ],
        'scanning': _hub.isScanning,
      };

  Future<void> dispose() async {
    for (final buf in _buffers.values) {
      await buf.streamSub?.cancel();
    }
    _buffers.clear();
    await _hub.dispose();
  }
}

class _Buffered {
  _Buffered(this.sub);
  final BleScanSubscription sub;
  StreamSubscription<BleAdvertisement>? streamSub;

  // Latest-per-device: one slot per deviceId with its freshest advertisement,
  // insertion-ordered so `window()` newest-first is a stable chart series.
  final Map<String, BleAdvertisement> _byDevice = {};

  int get count => _byDevice.length;

  void add(BleAdvertisement ad, int cap) {
    _byDevice.remove(ad.deviceId); // re-insert to move to the end (newest)
    _byDevice[ad.deviceId] = ad;
    while (_byDevice.length > cap) {
      _byDevice.remove(_byDevice.keys.first); // evict oldest
    }
  }

  /// Newest-first snapshot.
  List<BleAdvertisement> window() => _byDevice.values.toList().reversed.toList();
}
