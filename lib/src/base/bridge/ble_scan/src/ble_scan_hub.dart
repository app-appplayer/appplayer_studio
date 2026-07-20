// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_scan/lib/src/ble_scan_hub.dart
// Regenerate with debug/tool/sync_ble_scan_fork.sh.
//
import 'dart:async';

import 'ble_advertisement.dart';
import 'ble_scan_radio.dart';

/// One consumer's live view of the scan — the handle a bundle app / agent holds.
class BleScanSubscription {
  BleScanSubscription._({
    required this.id,
    required this.filter,
    required this.events,
    required Future<void> Function() onCancel,
  }) : _onCancel = onCancel;

  /// Stable id (also the key an agent/tool passes to stop).
  final String id;

  /// The constraint this subscriber registered (its own, independent).
  final BleScanFilter filter;

  /// Advertisements matching [filter] — this subscriber's OWN stream.
  final Stream<BleAdvertisement> events;

  final Future<void> Function() _onCancel;

  /// Stop observing. Decrements the shared radio's ref-count; when the last
  /// subscription is cancelled the physical scan stops.
  Future<void> cancel() => _onCancel();
}

/// Multiplexes the single [BleScanRadio] across many concurrent subscriptions —
/// the "many concurrent subscriptions + each bundle app registers its own filter" model. Each [subscribe] gets
/// its own filter and its own stream (isolated: subscribers never see each
/// other's registration or events). The physical radio is ref-counted: it scans
/// while ≥1 subscription is open and stops when the last one is cancelled.
class BleScanHub {
  BleScanHub(this._radio);

  final BleScanRadio _radio;
  final Map<String, _Sub> _subs = {};
  StreamSubscription<BleAdvertisement>? _radioSub;
  int _counter = 0;

  /// Live subscription ids (for a `ble.scan.list` tool / diagnostics).
  Iterable<String> get subscriptionIds => List.unmodifiable(_subs.keys);
  bool get isScanning => _radioSub != null;

  /// Register a new observer with its own [filter]. Starts the radio if this is
  /// the first subscription.
  BleScanSubscription subscribe(BleScanFilter filter) {
    final id = 'ble-scan-${++_counter}';
    final controller = StreamController<BleAdvertisement>.broadcast();
    _subs[id] = _Sub(filter, controller);
    _ensureScanning();
    return BleScanSubscription._(
      id: id,
      filter: filter,
      events: controller.stream,
      onCancel: () => _drop(id),
    );
  }

  /// Cancel by id (the shape a `ble.scan.stop` tool uses). No-op if unknown.
  Future<void> cancelById(String id) => _drop(id);

  /// Cancel everything and stop the radio.
  Future<void> dispose() async {
    final ids = _subs.keys.toList();
    for (final id in ids) {
      await _subs.remove(id)?.controller.close();
    }
    await _stopScanning();
  }

  // Fan-out: deliver each advertisement to every subscription whose filter
  // matches. Filtering is per-subscription, so one radio feeds N different views.
  void _onAd(BleAdvertisement ad) {
    for (final sub in _subs.values) {
      if (!sub.controller.isClosed && sub.filter.matches(ad)) {
        sub.controller.add(ad);
      }
    }
  }

  void _ensureScanning() {
    if (_radioSub != null) return;
    _radioSub = _radio.advertisements.listen(_onAd, onError: _onError);
    // Fire-and-forget: start() faults surface on the radio's advertisements
    // stream (onError) rather than blocking subscribe().
    unawaited(_radio.start());
  }

  void _onError(Object error, StackTrace stack) {
    for (final sub in _subs.values) {
      if (!sub.controller.isClosed) sub.controller.addError(error, stack);
    }
  }

  Future<void> _drop(String id) async {
    final sub = _subs.remove(id);
    if (sub == null) return;
    await sub.controller.close();
    if (_subs.isEmpty) await _stopScanning();
  }

  Future<void> _stopScanning() async {
    final rs = _radioSub;
    _radioSub = null;
    await rs?.cancel();
    if (rs != null) await _radio.stop();
  }
}

class _Sub {
  _Sub(this.filter, this.controller);
  final BleScanFilter filter;
  final StreamController<BleAdvertisement> controller;
}
