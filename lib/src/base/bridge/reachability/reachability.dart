// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/reachability/lib/reachability.dart
// Regenerate with debug/tool/sync_reachability_fork.sh.
//
/// reachability — telling a host the moment a dead connection is worth
/// dialling again, instead of letting it wait out an interval it chose blindly.
///
/// A retry timer can only guess. A signal knows: the network came back, the
/// board is advertising again, the port reappeared. Where a signal exists the
/// interval stops deciding recovery latency — which is also why the interval no
/// longer has to be tuned aggressively to be good enough.
///
/// This recipe carries the **device-observation** half: [DeviceSightingHints]
/// runs a per-server watch for exactly the servers an open app is stalled on,
/// and the transport-specific observation is injected ([streamSightingWatch]
/// for push sources, [polledSightingWatch] for list reads and browse windows,
/// [schemeSightingWatch] to route by wire) — so a host binds its own BLE /
/// mDNS / serial stack and this stays pure Dart with no radio dependency.
///
/// The **other half lives in the host core**, not here: the network-regain
/// edge needs no radio and no plugin, every AppPlayer tier already depends on
/// `appplayer_core`, and it is the only signal a remote / cloud server has
/// (nothing local ever sights an HTTPS endpoint). See
/// `AppPlayerCoreService.bindOnlineChanges`. Splitting it this way is what
/// keeps a tier with no local wires from taking a dependency it cannot use.
///
/// Neither half replaces the timed retry: a device can come back with no
/// advertisement heard, and a cloud server can recover with nothing local
/// changing at all. Signals accelerate recovery; the timer is the floor.
///
/// Vendored / path-consumed by hosts (AppPlayer tiers, Studio); publish_to:
/// none, no core package is modified.
library;

export 'src/device_sighting.dart'
    show
        DeviceSightingHints,
        SightingSource,
        SightingWatch,
        polledSightingWatch,
        schemeOf,
        schemeSightingWatch,
        streamSightingWatch,
        watchableEndpoint;
