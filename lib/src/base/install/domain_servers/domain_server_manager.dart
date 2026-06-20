/// `DomainServerManager` — single owner of every MCP server instance
/// the studio process exposes. Pool is **keyed by URL**, not domain:
/// any number of domains can attach to the same instance and share
/// its transport (multiplex). One instance per URL.
///
/// Two instance kinds:
///   * `system` — bound at studio boot. Always alive. Default attach
///     target for domains with `inheritFromSystem = true` (or those
///     whose listen URL happens to equal the system URL).
///   * `domainSpawned` — created lazily when a domain with
///     `inheritFromSystem = false` declares a URL not yet in the pool.
///     Torn down when every attached domain detaches.
///
/// Phase 3 ships only the system half: the manager is constructed
/// after the system server boots, tracks that one instance, and
/// exposes [status] for debug surfaces. `attach` / `detach` /
/// `spawn` land in later phases.
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;

/// Lifecycle state of one server instance in the pool. `failed` is
/// used by later phases when a `domainSpawned` bind throws (host
/// port already in use, etc.) — the manager stays loud (no silent
/// fallback) per the fix-at-source rule.
enum ServerState { active, spawning, teardown, failed }

/// Distinguishes the always-alive system instance from instances
/// created on demand for `inheritFromSystem = false` domains. The
/// system instance is never torn down even when no domain references
/// it (the studio chat / introspection always needs it).
enum ServerKind { system, domainSpawned }

/// One pooled MCP server instance keyed by URL.
class ServerInstance {
  ServerInstance({
    required this.url,
    required this.boot,
    required this.kind,
    this.state = ServerState.active,
    this.error,
  });

  /// Listen URL — `'http://host:port'`. Pool key.
  final String url;

  /// Owning `ServerBootstrap` (mcp_server wrapper). The boot owns
  /// the underlying transport instance; the manager only holds the
  /// reference so attach/detach can register/unregister tools &
  /// resources against it.
  final mk.KernelServerHost boot;

  /// `system` (boot-time, always-alive) vs `domainSpawned` (lazy).
  final ServerKind kind;

  /// Bundle ids currently sharing this instance. The system
  /// instance starts with an empty list; entries land as domains
  /// attach. `domainSpawned` instances are torn down when this
  /// goes empty.
  final List<String> attachedDomains = <String>[];

  /// Active / spawning / teardown / failed.
  ServerState state;

  /// Non-null when [state] is `failed`. Surfaced through [status].
  String? error;

  /// JSON-serialisable snapshot for `studio.debug.servers` /
  /// statusbar UI.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'kind': kind.name,
    'state': state.name,
    'attachedDomains': List<String>.from(attachedDomains),
    if (error != null) 'error': error,
  };
}

/// Host-supplied factory the manager calls when it needs to bind a
/// new `domainSpawned` instance at the given URL. Hosts construct a
/// fresh `ServerBootstrap`, start its transport at the URL, and
/// return the bound bootstrap. Throwing surfaces as `failed` state
/// (Phase 7).
typedef DomainServerSpawnFn = Future<mk.KernelServerHost> Function(String url);

/// Result of an [DomainServerManager.attach] call. Callers route
/// `failed` outcomes to user-visible toasts so the operator knows
/// the domain MCP server is disabled (and why).
class AttachOutcome {
  const AttachOutcome.success({required this.url, required this.kind})
    : ok = true,
      error = null;

  const AttachOutcome.failed({required this.url, required this.error})
    : ok = false,
      kind = ServerKind.domainSpawned;

  final bool ok;
  final String url;
  final ServerKind kind;
  final String? error;
}

class DomainServerManager {
  DomainServerManager._({
    required this.systemUrl,
    required ServerInstance system,
    required this.spawn,
  }) {
    _servers[systemUrl] = system;
  }

  /// Construct after the studio's system server has bound its
  /// transport. The instance is registered in the pool keyed by
  /// [url] and tagged `ServerKind.system`. [spawn] is the host's
  /// factory the manager invokes to bind new `domainSpawned`
  /// instances on demand (Phase 5).
  factory DomainServerManager.bootWithSystem({
    required mk.KernelServerHost boot,
    required String url,
    required DomainServerSpawnFn spawn,
  }) {
    final system = ServerInstance(
      url: url,
      boot: boot,
      kind: ServerKind.system,
    );
    return DomainServerManager._(systemUrl: url, system: system, spawn: spawn);
  }

  /// Factory invoked when a domain references a URL not yet in the
  /// pool. Returns the bound `ServerBootstrap` (transport already
  /// started). Hosts that fail to bind throw — the manager catches,
  /// marks the instance `failed`, and surfaces via [status].
  final DomainServerSpawnFn spawn;

  /// Pool key. Equal to the system server's listen URL — domains
  /// whose effective URL matches this resolve to the system
  /// instance instead of spawning a new one.
  final String systemUrl;

  final Map<String, ServerInstance> _servers = <String, ServerInstance>{};

  /// Look up a pooled instance by URL. `null` when no instance
  /// has been bound at that URL yet (Phase 5 spawn opportunity).
  ServerInstance? findByUrl(String url) => _servers[url];

  /// Look up which URL the given bundle is currently attached to.
  /// Returns the system URL when the bundle sits on the system
  /// instance; the spawned URL when it sits on a domainSpawned one.
  /// Null when the bundle is not attached anywhere.
  String? urlForBundle(String bundleId) {
    for (final entry in _servers.entries) {
      if (entry.value.attachedDomains.contains(bundleId)) {
        return entry.key;
      }
    }
    return null;
  }

  /// Read-only snapshot — JSON-shaped for the debug surface.
  /// One entry per pooled instance. Order is insertion (system
  /// first, then any domainSpawned instances).
  List<Map<String, dynamic>> status() => <Map<String, dynamic>>[
    for (final inst in _servers.values) inst.toJson(),
  ];

  /// Attach an active bundle to the appropriate pool instance.
  ///
  /// Resolution:
  ///   * `inheritFromSystem = true` → attach to the system instance.
  ///   * `inheritFromSystem = false` + `url == systemUrl` (or empty) →
  ///     same as inherit (URL-grouping multiplex).
  ///   * `inheritFromSystem = false` + `url` already in pool →
  ///     multiplex onto that instance.
  ///   * `inheritFromSystem = false` + new `url` → invoke [spawn] to
  ///     bind a new instance at that URL. Bind failure leaves the
  ///     instance in the pool tagged `failed` so [status] surfaces
  ///     it; the bundle stays unattached (Phase 7 — fail-noisy).
  ///
  /// Idempotent — re-attach of an already-attached bundle is a no-op
  /// on the bundle's existing instance. Returns an [AttachOutcome]
  /// describing what happened so the caller can surface a toast
  /// when the attach failed (Phase 7 — fail-noisy).
  Future<AttachOutcome> attach(
    String bundleId, {
    required bool inheritFromSystem,
    String? url,
  }) async {
    // First remove any prior attachment so re-attach after settings
    // change lands on the right instance.
    detach(bundleId);
    final target = await _resolveAttachTarget(
      inheritFromSystem: inheritFromSystem,
      url: _normalizeUrl(url),
    );
    if (target == null) {
      // _resolveAttachTarget left a `failed` placeholder in the pool
      // for the URL it tried; surface its error.
      final normalized = _normalizeUrl(url);
      final effective =
          (inheritFromSystem || normalized == null || normalized.isEmpty)
              ? systemUrl
              : normalized;
      final failedInst = _servers[effective];
      return AttachOutcome.failed(
        url: effective,
        error: failedInst?.error ?? 'unknown spawn failure',
      );
    }
    if (target.state != ServerState.active) {
      return AttachOutcome.failed(
        url: target.url,
        error: target.error ?? 'instance not active',
      );
    }
    if (!target.attachedDomains.contains(bundleId)) {
      target.attachedDomains.add(bundleId);
    }
    return AttachOutcome.success(url: target.url, kind: target.kind);
  }

  /// Detach a bundle from whatever instance it sits on. Removes the
  /// id from `attachedDomains`; if the resulting instance is a
  /// `domainSpawned` one with no remaining domains, tear it down.
  /// System instance never tears down.
  void detach(String bundleId) {
    final empties = <String>[];
    for (final entry in _servers.entries) {
      final inst = entry.value;
      inst.attachedDomains.remove(bundleId);
      if (inst.kind == ServerKind.domainSpawned &&
          inst.attachedDomains.isEmpty) {
        empties.add(entry.key);
      }
    }
    for (final url in empties) {
      // Fire-and-forget transport shutdown — ServerBootstrap.shutdown()
      // closes the underlying transport. Wrapped in a try so a
      // misbehaving transport never blocks detach.
      try {
        // ignore: unawaited_futures
        _servers[url]?.boot.shutdown();
      } catch (_) {
        /* best-effort */
      }
      _servers.remove(url);
    }
  }

  /// Normalize override-supplied URLs so they match the system URL
  /// convention (always include the `/mcp` Streamable HTTP endpoint
  /// path). Domains may write `http://host:port` in their override
  /// file by mistake; without normalization that maps to a separate
  /// pool key from the actual listening endpoint at `/mcp` and would
  /// spawn a duplicate / fail on port reuse. Returns null untouched
  /// (caller treats null as "fall back to system").
  String? _normalizeUrl(String? raw) {
    if (raw == null || raw.isEmpty) return raw;
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    if (uri.path.isEmpty || uri.path == '/') {
      return uri.replace(path: '/mcp').toString();
    }
    return raw;
  }

  Future<ServerInstance?> _resolveAttachTarget({
    required bool inheritFromSystem,
    required String? url,
  }) async {
    if (inheritFromSystem) return _servers[systemUrl];
    final effective = (url == null || url.isEmpty) ? systemUrl : url;
    final existing = _servers[effective];
    if (existing != null) return existing;
    // New URL — ask the host to spawn a fresh server.
    try {
      final boot = await spawn(effective);
      final inst = ServerInstance(
        url: effective,
        boot: boot,
        kind: ServerKind.domainSpawned,
      );
      _servers[effective] = inst;
      return inst;
    } catch (e) {
      // Bind failed (port already in use by external process, etc.).
      // Pool keeps a `failed` placeholder so the debug surface shows
      // what happened. No system fallback — the bundle's domain MCP
      // server stays disabled until the user changes the URL or
      // stops the conflicting process.
      _servers[effective] = ServerInstance(
        url: effective,
        boot: _servers[systemUrl]!.boot, // sentinel — never used
        kind: ServerKind.domainSpawned,
        state: ServerState.failed,
        error: '$e',
      );
      return null;
    }
  }
}
