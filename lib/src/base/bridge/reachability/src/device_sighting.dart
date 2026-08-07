// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/reachability/lib/src/device_sighting.dart
// Regenerate with debug/tool/sync_reachability_fork.sh.
//
import 'dart:async';

/// A per-server observation: start listening on one endpoint, call back the
/// first time the device is seen, and return the canceller.
///
/// "Seen" differs by wire — a BLE peripheral advertises, an mDNS node
/// announces, a USB port reappears in the OS list. None of those requires
/// dialling the device, which is what makes them usable while a dial would be
/// expensive, blocked, or pointless.
typedef SightingWatch = Future<void> Function() Function(
  String endpoint,
  void Function() onSighted,
);

/// A push observation and the handle that releases it. Kept together because
/// cancelling a stream subscription does not always release the underlying
/// source — a shared BLE radio hub hands out a stream AND a subscription that
/// must be cancelled for the radio to stop.
class SightingSource {
  const SightingSource({required this.events, required this.close});

  final Stream<void> events;
  final Future<void> Function() close;
}

/// Watch built on a push source (BLE advertisements, a platform hotplug feed).
/// Passive: the device is talking anyway, the host just stops ignoring it.
SightingWatch streamSightingWatch(SightingSource Function(String endpoint) open) {
  return (endpoint, onSighted) {
    final source = open(endpoint);
    final sub = source.events.listen((_) => onSighted());
    return () async {
      await sub.cancel();
      await source.close();
    };
  };
}

/// Watch built on a predicate that is asked periodically — a port list read, an
/// mDNS browse window. Polled, but it is an observation, not a dial: no
/// handshake, no session, nothing on the device to refuse it.
///
/// A slow predicate is never re-entered; a throwing one is treated as "not
/// seen", because a failed browse window is not information.
SightingWatch polledSightingWatch(
  Future<bool> Function(String endpoint) present, {
  Duration every = const Duration(seconds: 2),
  bool immediate = true,
}) {
  return (endpoint, onSighted) {
    var running = false;
    Future<void> tick() async {
      if (running) return;
      running = true;
      try {
        if (await present(endpoint)) onSighted();
      } catch (_) {
        // Not information — the next window runs.
      } finally {
        running = false;
      }
    }

    if (immediate) unawaited(tick());
    final timer = Timer.periodic(every, (_) => unawaited(tick()));
    return () async => timer.cancel();
  };
}

/// Routes an endpoint to the watch registered for its URI scheme. A scheme with
/// no entry gets no watch — a statement that the network signal is that
/// server's path, not a failure.
SightingWatch schemeSightingWatch(Map<String, SightingWatch> byScheme) {
  return (endpoint, onSighted) {
    final watch = byScheme[schemeOf(endpoint)];
    if (watch == null) return () async {};
    return watch(endpoint, onSighted);
  };
}

/// Scheme of an endpoint (`ble://AA:BB` → `ble`), or null when there is none.
String? schemeOf(String? endpoint) {
  if (endpoint == null) return null;
  final i = endpoint.indexOf('://');
  return i <= 0 ? null : endpoint.substring(0, i);
}

/// The endpoint when it is one of [watchable], else null. `https://…` resolves
/// to null on purpose: there is nothing local to listen for, and that server is
/// served by the host core's network-regain binding instead
/// (`AppPlayerCoreService.bindOnlineChanges`).
String? watchableEndpoint(String? endpoint, Set<String> watchable) {
  final scheme = schemeOf(endpoint);
  if (scheme == null || !watchable.contains(scheme)) return null;
  return endpoint;
}

/// Runs a [SightingWatch] for exactly the servers an open app is stalled on:
/// starts one when a server enters that set, cancels when it leaves.
///
/// The set comes from the host (`AppPlayerCoreService.stalledServers`). Scoping
/// it this way is the whole discipline — observing every server ever registered
/// is an always-on scan, which is the cost hosts deliberately scope discovery
/// away from. A radio runs for the screen someone is waiting on, and stops.
class DeviceSightingHints {
  DeviceSightingHints({
    required Set<String> Function() stalled,
    required String? Function(String serverId) endpointOf,
    required SightingWatch watch,
    required void Function(String serverId) onSighted,
  })  : _stalled = stalled,
        _endpointOf = endpointOf,
        _watch = watch,
        _onSighted = onSighted;

  final Set<String> Function() _stalled;
  final String? Function(String serverId) _endpointOf;
  final SightingWatch _watch;
  final void Function(String serverId) _onSighted;

  final Map<String, Future<void> Function()> _active = {};

  /// Server ids currently being listened for — diagnostics, and the thing to
  /// assert on, since "the radio stopped" is otherwise invisible.
  Iterable<String> get watching => List.unmodifiable(_active.keys);

  /// Re-read the stalled set and reconcile. Hosts call this whenever connection
  /// or app state changes (on AppPlayer: `core.lifecycleListenable`).
  void refresh() {
    final want = _stalled();

    for (final serverId in _active.keys.toList()) {
      if (!want.contains(serverId)) {
        final cancel = _active.remove(serverId);
        if (cancel != null) unawaited(cancel());
      }
    }

    for (final serverId in want) {
      if (_active.containsKey(serverId)) continue;
      final endpoint = _endpointOf(serverId);
      if (endpoint == null) continue;
      _active[serverId] = _watch(endpoint, () => _onSighted(serverId));
    }
  }

  Future<void> stop() async {
    final cancels = _active.values.toList();
    _active.clear();
    for (final cancel in cancels) {
      await cancel();
    }
  }
}
