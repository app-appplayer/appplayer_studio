/// Binds the studio's own observation stack to the reconnect watch — the
/// signal half of platform spec 17 §7.6e.
///
/// The watch already recovers a dropped connection on its own: it dials, waits,
/// dials again, for as long as a screen is open. That interval is a guess
/// though, and the guess is what decides how long a user stares at an error
/// after the board is already back. A BLE peripheral announces itself before
/// anyone connects to it, so the studio can simply hear it and dial then.
///
/// Three things this must not become:
///
///  - **A dial.** Listening to advertisements opens no session, so it stays
///    outside the single-peer constraint (spec 17 §7.6b) that makes the studio
///    refuse to hold registered boards open. Nothing here probes.
///  - **An always-on scan.** The watch's stalled set is the scope, so the radio
///    runs for connections a mounted view is waiting on and stops when that
///    view closes. Observing everything ever registered would undo the reason
///    discovery is tied to screen lifetime in the first place.
///  - **A replacement for the timer.** An advertisement can be missed, and an
///    endpoint with no local signal at all (anything over https) is only ever
///    recovered by the loop. This accelerates; it does not take over.
///
/// The BLE hub is the studio's single multiplexed radio ([studioBleStack]), so
/// a per-server subscription here costs a filter, not a second scan — and its
/// cancel handle is what actually lets the radio stop, which is why
/// [SightingSource] carries the release rather than just the stream.
library;

import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import '../bridge/ble_scan/ble_scan.dart' show BleScanFilter, BleScanHub;
import '../bridge/ble_stack.dart' show studioBleStack;
import '../bridge/reachability/reachability.dart'
    show
        DeviceSightingHints,
        SightingSource,
        SightingWatch,
        schemeSightingWatch,
        streamSightingWatch;
import 'reconnect_watch.dart' show StudioReconnectWatch;

/// Connection id → an endpoint the observation layer can route on.
///
/// BLE board connections are opened as `ble:<deviceId>`
/// (`StudioDiscovery.connectCandidate`), which becomes `ble://<deviceId>` so
/// the recipe's scheme routing can dispatch it. Everything else returns null on
/// purpose: an https endpoint has nothing local to listen for, and a custom id
/// carries no device to observe. Those are not failures — they are connections
/// the timed loop owns alone.
String? studioSightingEndpoint(String connectionId) {
  const blePrefix = 'ble:';
  if (!connectionId.startsWith(blePrefix)) return null;
  final deviceId = connectionId.substring(blePrefix.length);
  if (deviceId.isEmpty || deviceId.startsWith('//')) return null;
  return 'ble://$deviceId';
}

/// A watch over the studio's shared BLE radio: one filtered subscription per
/// device, released when the device is no longer stalled.
SightingWatch studioBleSightingWatch(BleScanHub hub) {
  return streamSightingWatch((endpoint) {
    final deviceId = endpoint.substring('ble://'.length);
    final sub = hub.subscribe(BleScanFilter(deviceIds: <String>[deviceId]));
    return SightingSource(events: sub.events, close: sub.cancel);
  });
}

/// Turns "this app came back to the foreground" into a reachability hint.
///
/// The signal an https endpoint would want is the network-regain edge, and the
/// studio has no connectivity plugin to read it from. Adding one to the open
/// tree buys little here: a screen on display is dialled every few seconds with
/// no backoff and no cap, so a remote server's recovery is already bounded by
/// that floor rather than by a long interval.
///
/// Resume is the part worth catching anyway, because it is where the floor and
/// reality diverge: a laptop that slept had its timers suspended with it, and
/// it wakes with the network in whatever state sleep left it. The first thing
/// to do on waking is to try again, not to serve out the remainder of an
/// interval that was measured before the machine went away.
///
/// Free of dependencies — the framework already reports this.
class StudioResumeHint with WidgetsBindingObserver {
  StudioResumeHint(this._watch);

  final StudioReconnectWatch _watch;
  AppLifecycleState? _last;

  void start() => WidgetsBinding.instance.addObserver(this);
  void stop() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final was = _last;
    _last = state;
    // The EDGE, not the state: a host that is already foregrounded and reports
    // it again must not dial, for the same reason a repeated "connected" from
    // a platform's connectivity feed must not.
    if (was != null &&
        was != AppLifecycleState.resumed &&
        state == AppLifecycleState.resumed) {
      _watch.hintReachable();
    }
  }
}

/// Wires sighting into [watch] and keeps it reconciled with the stalled set.
///
/// Returns the hints so a host that tears its wiring down can stop the radio;
/// callers that live for the process can ignore it.
DeviceSightingHints bindStudioReachabilitySignals(
  StudioReconnectWatch watch, {
  BleScanHub? hub,
  bool bindResume = true,
}) {
  if (bindResume) StudioResumeHint(watch).start();
  final hints = DeviceSightingHints(
    stalled: () => watch.stalledServers,
    endpointOf: studioSightingEndpoint,
    watch: schemeSightingWatch(<String, SightingWatch>{
      'ble': studioBleSightingWatch(hub ?? studioBleStack.hub),
    }),
    onSighted: watch.hintReachable,
  );
  // The watch ticks whenever a connection is held, released, or changes
  // liveness — which is exactly when the set of things worth listening for
  // changes. Without this the radio would be started once and never rescoped.
  watch.changes.addListener(hints.refresh);
  hints.refresh();
  return hints;
}
