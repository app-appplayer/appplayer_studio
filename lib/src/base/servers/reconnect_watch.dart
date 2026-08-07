/// Keeps a dropped connection being dialled for as long as a screen is waiting
/// on it — the host half of platform spec 17 §7.6d.
///
/// The studio does not hold registered devices open (see
/// `LocalServerManager.reopen`: single-peer boards reset each other), so a
/// connection exists exactly while something is rendering it. That makes "an
/// app is open" a precise, local fact here: a served view HOLDS its connection
/// id while mounted and RELEASES it on dispose. Nothing is watched for a screen
/// nobody is looking at.
///
/// What the spec forbids, and how this shape avoids it:
///
///  - **No attempt cap.** There is no counter anywhere in this file. A capped
///    retry can only be reset by observing a success, and after it gives up
///    there is nothing left to observe it — so the recovery it removes is its
///    own. While an id is held and dead, the loop keeps dialling.
///  - **Detection and retry are different knobs.** [detectInterval] decides how
///    fast a drop is NOTICED (the kernel exposes `isConnected` as a plain
///    property, with no disconnect stream, so noticing has to be polled).
///    [retryInterval] decides how often a dial is ATTEMPTED. Tightening the
///    first to react faster must not accelerate the second — the bug this
///    guards against turned a 2s detector into a 15x faster retry.
///  - **Dials never overlap.** One loop per id, and the interval is awaited
///    AFTER a dial settles, so the gap is between dials rather than on top of
///    them. Overlapping dials at a single-peer board have the newer session
///    reset the older one (spec 17 §7.6b).
///  - **A dial is bounded.** [dialTimeout] caps one attempt, because a dial
///    that hangs forever stops the retry loop just as effectively as giving up.
///  - **No backoff.** A screen on display is a standing declaration that this
///    connection is wanted; there is nothing to gain by waiting longer. Backoff
///    is for connections nobody is watching.
///
/// The timer is the FLOOR, not the mechanism (spec 17 §7.6e): [hintReachable]
/// cuts the remaining wait when something observes the device is back, and
/// [bindOnlineChanges] does it for the network-regain edge, which is the only
/// signal a remote/cloud endpoint ever gets. Neither replaces the loop — an
/// advertisement can be missed and a cloud server can recover silently.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Re-establishes the connection for [id]. Studio binds
/// `LocalServerManager.reopen`; it is a parameter so this file stays testable
/// without a kernel host.
typedef ReconnectDial = Future<void> Function(String id);

class StudioReconnectWatch {
  StudioReconnectWatch({
    required bool Function(String id) isLive,
    required ReconnectDial dial,
    bool Function(String id)? canDial,
    this.detectInterval = const Duration(seconds: 2),
    this.retryInterval = const Duration(seconds: 5),
    this.dialTimeout = const Duration(seconds: 15),
  })  : _isLive = isLive,
        _dial = dial,
        _canDial = canDial ?? _alwaysDialable;

  static bool _alwaysDialable(String _) => true;

  final bool Function(String id) _isLive;
  final ReconnectDial _dial;

  /// Whether a route back exists at all. An id with no route is not "stalled",
  /// it is unreachable: retrying it would burn a dial every interval and
  /// observing it would keep a radio on for a recovery that cannot happen.
  final bool Function(String id) _canDial;

  /// How fast a drop is noticed. Independent of [retryInterval] on purpose.
  final Duration detectInterval;

  /// How often a dial is attempted, measured between dials.
  final Duration retryInterval;

  /// Ceiling on a single dial, so a hung attempt cannot stall the loop.
  final Duration dialTimeout;

  /// id → number of mounted views waiting on it. A count, not a flag: two tabs
  /// may render the same server, and the first one closing must not stop the
  /// watch the second still needs.
  final Map<String, int> _held = <String, int>{};

  /// ids whose retry loop is currently running (one per id — the overlap rule).
  final Set<String> _looping = <String>{};

  /// id → the completer a signal completes to cut the current wait short.
  final Map<String, Completer<void>> _wakes = <String, Completer<void>>{};

  Timer? _detect;
  StreamSubscription<bool>? _onlineSub;
  bool? _lastOnline;
  bool _disposed = false;

  /// Ticks whenever the watched set or a liveness state changes. Views listen
  /// to re-render the moment their connection is back, and the sighting binding
  /// listens to reconcile which devices it observes.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// Connection ids a mounted view is waiting on that are not currently live —
  /// the set device observation must be scoped to (spec 17 §7.6e: watching
  /// everything ever registered is an always-on scan).
  Set<String> get stalledServers => <String>{
        for (final id in _held.keys)
          if (!_isLive(id) && _canDial(id)) id,
      };

  /// Ids with a mounted view, live or not. Diagnostics.
  Iterable<String> get held => List<String>.unmodifiable(_held.keys);

  /// A view rendering [id] has mounted. Idempotent per view — each [hold] must
  /// be paired with exactly one [release].
  void hold(String id) {
    if (_disposed) return;
    _held[id] = (_held[id] ?? 0) + 1;
    _ensureDetecting();
    _bump();
    // Do not wait for the first detect tick: a view that mounts onto an
    // already-dead connection is the common case (the tab outlived a drop).
    _startLoop(id);
  }

  /// The view rendering [id] has been disposed. The loop for [id] stops as soon
  /// as the last holder is gone — this is what bounds retrying to open apps.
  void release(String id) {
    final n = _held[id];
    if (n == null) return;
    if (n <= 1) {
      _held.remove(id);
      // The loop reads _held on its next turn and exits; waking it makes that
      // turn happen now instead of one interval later.
      _wake(id);
    } else {
      _held[id] = n - 1;
    }
    if (_held.isEmpty) {
      _detect?.cancel();
      _detect = null;
    }
    _bump();
  }

  /// Something observed that the device is reachable again: cut the remaining
  /// wait and dial now. With no [id], applies to every stalled connection —
  /// the network-regain signal cannot name a server.
  void hintReachable([String? id]) {
    if (_disposed) return;
    if (id != null) {
      _wake(id);
      _startLoop(id);
      return;
    }
    for (final held in _held.keys.toList()) {
      _wake(held);
      _startLoop(held);
    }
  }

  /// Binds a connectivity feed. Fires [hintReachable] on the offline→online
  /// EDGE only: the first event is a report of current state rather than a
  /// transition (binding at startup would otherwise dial immediately), and
  /// platforms repeat "connected" per interface, which would dial on every
  /// repeat.
  void bindOnlineChanges(Stream<bool> online) {
    _onlineSub?.cancel();
    _lastOnline = null;
    _onlineSub = online.listen((isOnline) {
      final was = _lastOnline;
      _lastOnline = isOnline;
      if (was == false && isOnline) hintReachable();
    });
  }

  void _ensureDetecting() {
    _detect ??= Timer.periodic(detectInterval, (_) => _detectTick());
  }

  /// Notices drops and recoveries. Deliberately does NOT dial — it only arms
  /// the loop, so tightening [detectInterval] cannot speed up dialling.
  void _detectTick() {
    var changed = false;
    for (final id in _held.keys.toList()) {
      if (_isLive(id)) {
        if (_looping.contains(id)) changed = true;
      } else if (!_looping.contains(id)) {
        changed = true;
        _startLoop(id);
      }
    }
    if (changed) _bump();
  }

  void _startLoop(String id) {
    if (_disposed) return;
    if (_looping.contains(id)) return;
    if (!_held.containsKey(id)) return;
    if (_isLive(id)) return;
    if (!_canDial(id)) return;
    _looping.add(id);
    unawaited(_loop(id));
  }

  /// Dial, wait, dial — with no ceiling on how many times. Exits only when the
  /// connection is live again or nothing is holding [id] any more.
  Future<void> _loop(String id) async {
    try {
      while (!_disposed && _held.containsKey(id) && _canDial(id)) {
        if (_isLive(id)) {
          _bump();
          return;
        }
        try {
          await _dial(id).timeout(dialTimeout);
        } catch (_) {
          // A failed dial is the normal case here — the device is away. The
          // interval below is what keeps this from becoming a spin.
        }
        if (_isLive(id)) {
          _bump();
          return;
        }
        if (!_held.containsKey(id) || _disposed) return;
        // Interval AFTER the attempt settles: gap between dials, never a second
        // dial laid on top of one still in flight.
        await _waitBeforeNextDial(id);
      }
    } finally {
      _looping.remove(id);
    }
  }

  /// The retry gap, interruptible by [hintReachable].
  Future<void> _waitBeforeNextDial(String id) {
    final wake = Completer<void>();
    _wakes[id] = wake;
    final timer = Timer(retryInterval, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.whenComplete(() {
      timer.cancel();
      if (identical(_wakes[id], wake)) _wakes.remove(id);
    });
  }

  void _wake(String id) {
    final wake = _wakes[id];
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _bump() {
    if (_disposed) return;
    changes.value++;
  }

  void dispose() {
    // Idempotent: a host may tear down its wiring and its owner may dispose
    // again, and a second `changes.dispose()` would throw.
    if (_disposed) return;
    _disposed = true;
    _detect?.cancel();
    _detect = null;
    _onlineSub?.cancel();
    _onlineSub = null;
    for (final wake in _wakes.values) {
      if (!wake.isCompleted) wake.complete();
    }
    _wakes.clear();
    _held.clear();
    changes.dispose();
  }
}
