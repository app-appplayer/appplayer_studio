/// Host-level browser capability.
///
/// Exposes the 9 `mcp_browser` operations as `browser.*` tools on the
/// host's [HostToolRegistry], so every built-in (ops, app_builder, …) and
/// bundle app shares one browser engine instead of each booting its own.
/// This is the parity rule made concrete: a general capability is
/// host-owned and merely *used* by domains, never re-implemented inside
/// one of them.
///
/// The engine boots lazily from the host's configured Chromium path
/// (read fresh per call via the [chromiumPath] getter, so a settings
/// hot-swap re-boots on the next call). When the path is null/empty the
/// tools still register but report `browser.disabled` when invoked.
library;

import 'dart:convert' show jsonEncode, jsonDecode, utf8;
import 'dart:io' show Directory, File, HttpClient;
import 'dart:typed_data' show Uint8List;

import 'package:appplayer_secure/appplayer_secure.dart'
    show AtRestSealer, FlutterSecureStorageBackend;
import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_browser/mcp_browser.dart';
import 'package:path/path.dart' as p;

/// Default at-rest sealer for browser auth profiles — keyed by an
/// OS-keychain-backed [FlutterSecureStorageBackend]. Hosts pass the
/// result to [registerBrowserCapability] as `authSealer`. Constructing it
/// here keeps the call site from importing `appplayer_secure` directly.
AtRestSealer defaultAuthSealer() =>
    AtRestSealer(storage: FlutterSecureStorageBackend());

/// The 9 first-class browser operations.
const List<String> browserOperationIds = <String>[
  'page_view',
  'page_audit_role',
  'web_search',
  'extract',
  'crawl',
  'monitor',
  'submit_form',
  'download',
  'page_compare_actors',
];

/// Capability namespace — exposed names are `browser.<op>`.
const String browserCapabilityId = 'browser';

/// Register `browser.<op>` for all 9 operations onto [registry]. Returns
/// the exposed names. [chromiumPath] is read on each call so a settings
/// change is picked up without a restart.
///
/// When [authSealer] and [authRoot] are both supplied, the engine is wired
/// with a [SealedAuthProfileStore] so:
///   - `browser.auth_capture` extracts a logged-in context's cookies +
///     storage and persists them as an encrypted `.enc` profile (S2-core;
///     replaces ops' former plaintext `BrowserAuthProfile` write), and
///   - the standard ops (`page_view {actor, tenantId}`, …) re-inject a
///     stored profile via `setAuth` (S2-apply) — the host's
///     `BrowserAuthProfilePort` backs `BrowserRuntime.authStore`.
/// [authRoot] is the directory tree (`<root>/<tenant>/<id>.enc`) profiles
/// live under; it is read fresh so it tracks a settings/workspace change.
List<String> registerBrowserCapability({
  required HostToolRegistry registry,
  required String? Function() chromiumPath,
  BrowserEngineConfig Function()? engineConfig,
  AtRestSealer? authSealer,
  String? Function()? authRoot,
}) {
  final store =
      (authSealer != null && authRoot != null)
          ? SealedAuthProfileStore(sealer: authSealer, rootDir: authRoot)
          : null;
  final engine = _LazyBrowserEngine(chromiumPath, store, engineConfig);
  // Dedicated headful engine for interactive auth capture (login window the
  // user can see), separate from the headless scraping engine. Lazy — no
  // headful Chromium until an auth flow runs. Only when auth is configured.
  final authEngine =
      store != null
          ? _LazyBrowserEngine(
            chromiumPath,
            store,
            engineConfig,
            headless: false,
          )
          : null;
  final exposed = <String>[];
  for (final opId in browserOperationIds) {
    exposed.add(
      registry.registerExposed(
        bundleId: browserCapabilityId,
        rawName: opId,
        description: 'mcp_browser operation: $opId',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'additionalProperties': true,
        },
        handler: (args) => _dispatch(engine, opId, args),
      ),
    );
  }
  if (store != null) {
    exposed.add(
      registry.registerExposed(
        bundleId: browserCapabilityId,
        rawName: 'open_login',
        description:
            'Open a system\'s login page in a headful (visible) browser '
            'window so a user can sign in interactively, and return the '
            'contextId. The window stays open; after the user signs in, call '
            'browser.auth_capture with this contextId to seal the session.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'url': <String, dynamic>{
              'type': 'string',
              'description': 'Login URL to open.',
            },
            'tenantId': <String, dynamic>{
              'type': 'string',
              'description': 'Target system / tenant id.',
            },
          },
          'required': <String>['url'],
        },
        handler: (args) => _dispatchOpenLogin(authEngine!, args),
      ),
    );
    exposed.add(
      registry.registerExposed(
        bundleId: browserCapabilityId,
        rawName: 'auth_capture',
        description:
            'Capture cookies + storage from a logged-in browser context '
            'and persist them as an encrypted auth profile. Open the login '
            'page first via browser.open_login and pass its contextId here. '
            'Re-inject later by passing '
            'actor:"<member>-<system>" + tenantId:"<system>" to any op.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'member': <String, dynamic>{
              'type': 'string',
              'description': 'Member id the profile belongs to.',
            },
            'system': <String, dynamic>{
              'type': 'string',
              'description': 'Target system / tenant id.',
            },
            'contextId': <String, dynamic>{
              'type': 'string',
              'description': 'Persistent browser context to extract from.',
            },
          },
          'required': <String>['member', 'system', 'contextId'],
        },
        handler: (args) => _dispatchAuthCapture(authEngine!, store, args),
      ),
    );
  }
  return exposed;
}

/// Open a login URL in a headful (visible) context that stays alive, and
/// return its contextId. The user signs in, then `browser.auth_capture`
/// extracts + seals the session from this same (auth) engine. The context is
/// NOT released — it is reused by the capture and idles out afterward.
Future<KernelToolResult> _dispatchOpenLogin(
  _LazyBrowserEngine engine,
  Map<String, dynamic> args,
) async {
  try {
    final url = (args['url'] as String?)?.trim() ?? '';
    final tenantId = (args['tenantId'] as String?)?.trim() ?? '_default';
    if (url.isEmpty) {
      return _result(<String, dynamic>{
        'ok': false,
        'code': 'browser.bad_input',
        'error': 'url required',
      }, isError: true);
    }
    final runtime = await engine.runtimeOrNull();
    if (runtime == null) {
      return _result(<String, dynamic>{
        'ok': false,
        'code': 'browser.disabled',
        'error': 'Browser is disabled — set a Chromium path in settings.',
      }, isError: true);
    }
    final handle = await runtime.contexts.acquire(
      BrowserContextSpec(tenantId: tenantId, persistent: true),
    );
    await runtime.execute(handle.contextId, BrowserAction.navigate(url));
    return _result(<String, dynamic>{
      'ok': true,
      'contextId': handle.contextId,
    }, isError: false);
  } catch (e) {
    return _result(<String, dynamic>{
      'ok': false,
      'code': 'browser.open_login_failed',
      'error': e.toString(),
    }, isError: true);
  }
}

Future<KernelToolResult> _dispatch(
  _LazyBrowserEngine engine,
  String opId,
  Map<String, dynamic> args,
) async {
  try {
    final ops = await engine.operations();
    if (ops == null) {
      return _result(<String, dynamic>{
        'ok': false,
        'code': 'browser.disabled',
        'error': 'Browser is disabled — set a Chromium path in settings.',
      }, isError: true);
    }
    final op = ops.get(opId);
    if (op == null) {
      return _result(<String, dynamic>{
        'ok': false,
        'code': 'browser.unknown_op',
        'error': 'Unknown browser operation: $opId',
      }, isError: true);
    }
    var call = args;
    // DuckDuckGo HTML SERP needs no API key, so web_search works the
    // moment a Chromium path is set. Override by passing `provider`
    // (brave / google / kagi / …) once the matching key is configured.
    if (opId == 'web_search' && call['provider'] == null) {
      call = <String, dynamic>{...call, 'provider': 'ddg'};
    }
    final out = await op.handler(call);
    return _result(out, isError: false);
  } catch (e) {
    return _result(<String, dynamic>{
      'ok': false,
      'code': 'browser.error',
      'error': e.toString(),
    }, isError: true);
  }
}

/// Snapshot auth state from the live [args.contextId] and persist a sealed
/// profile through [store].
///
/// Uses the engine's `saveStorageState` (CDP `Network.getCookies` +
/// localStorage/sessionStorage) — the same primitive context persistence
/// uses — so **HttpOnly auth cookies are captured** (a `document.cookie`
/// script cannot read them). Bytes are sealed by [SealedAuthProfileStore]
/// (AEAD, key in SecureStorage), and the store is the same one `setAuth`
/// reads from for re-injection.
Future<KernelToolResult> _dispatchAuthCapture(
  _LazyBrowserEngine engine,
  SealedAuthProfileStore store,
  Map<String, dynamic> args,
) async {
  try {
    final member = (args['member'] as String?)?.trim() ?? '';
    final system = (args['system'] as String?)?.trim() ?? '';
    final contextId = (args['contextId'] as String?)?.trim() ?? '';
    if (member.isEmpty || system.isEmpty || contextId.isEmpty) {
      return _result(<String, dynamic>{
        'ok': false,
        'code': 'browser.bad_input',
        'error': 'member, system, contextId are all required',
      }, isError: true);
    }

    final runtime = await engine.runtimeOrNull();
    if (runtime == null) {
      return _result(<String, dynamic>{
        'ok': false,
        'code': 'browser.disabled',
        'error': 'Browser is disabled — set a Chromium path in settings.',
      }, isError: true);
    }
    final handle = runtime.contexts.lookup(contextId);
    if (handle == null) {
      return _result(<String, dynamic>{
        'ok': false,
        'code': 'browser.context_not_found',
        'error':
            'No live context "$contextId" — open the login page first '
            'via browser.page_view {persistent:true}.',
      }, isError: true);
    }

    // Same snapshot path persistent profiles use on context release.
    final port = runtime.engines.resolveContextPort(handle.engineId);
    final state = await port.saveStorageState(handle.enginePayload);

    final cookies = <BrowserCookie>[
      for (final c in (state['cookies'] as List? ?? const []))
        if (c is Map) _cookieFromCdp(c),
    ];
    final storage = (state['storage'] as Map?) ?? const <String, dynamic>{};
    final localStorage =
        (storage['localStorage'] as Map?)?.map(
          (Object? k, Object? v) => MapEntry<String, String>('$k', '$v'),
        ) ??
        const <String, String>{};
    final sessionStorage =
        (storage['sessionStorage'] as Map?)?.map(
          (Object? k, Object? v) => MapEntry<String, String>('$k', '$v'),
        ) ??
        const <String, String>{};

    final profile = BrowserAuthProfile(
      id: '$member-$system',
      tenantId: system,
      label: 'captured via host on ${DateTime.now().toIso8601String()}',
      cookies: cookies,
      localStorage: localStorage,
      sessionStorage: sessionStorage,
    );

    final path = await store.put(profile);

    return _result(<String, dynamic>{
      'ok': true,
      'profileId': profile.id,
      'tenantId': profile.tenantId,
      'path': path,
      'cookies': cookies.length,
      'localStorageKeys': localStorage.length,
      'sessionStorageKeys': sessionStorage.length,
    }, isError: false);
  } catch (e) {
    return _result(<String, dynamic>{
      'ok': false,
      'code': 'browser.auth_capture_failed',
      'error': e.toString(),
    }, isError: true);
  }
}

/// Map a CDP `Network.Cookie` map to a [BrowserCookie]. CDP `expires` is in
/// seconds (double); `-1` / absent means a session cookie (no expiry).
BrowserCookie _cookieFromCdp(Map<dynamic, dynamic> c) {
  final expires = c['expires'];
  final hasExpiry = expires is num && expires > 0;
  return BrowserCookie(
    name: c['name']?.toString() ?? '',
    value: c['value']?.toString() ?? '',
    domain: c['domain']?.toString(),
    path: c['path']?.toString() ?? '/',
    secure: c['secure'] == true,
    httpOnly: c['httpOnly'] == true,
    sameSite: c['sameSite']?.toString(),
    expires:
        hasExpiry
            ? DateTime.fromMillisecondsSinceEpoch(
              (expires * 1000).round(),
              isUtc: true,
            )
            : null,
  );
}

KernelToolResult _result(Object? value, {required bool isError}) {
  return KernelToolResult(
    content: <KernelContent>[KernelTextContent(text: jsonEncode(value))],
    isError: isError,
  );
}

/// Host-owned configuration for the shared `browser.*` engine. Applied on
/// each (re)boot. These were dead config in ops (stored but never wired into
/// the engine); the host now applies them so a built-in's browser settings
/// are a real feature. All knobs are optional — unset = mcp_browser defaults.
class BrowserEngineConfig {
  const BrowserEngineConfig({
    this.maxConcurrentContexts,
    this.userAgent,
    this.locale,
    this.timezone,
    this.viewport,
    this.respectRobots = false,
  });

  final int? maxConcurrentContexts;
  final String? userAgent;
  final String? locale;
  final String? timezone;

  /// `{width, height}` viewport applied to new contexts.
  final Map<String, int>? viewport;

  /// Enforce robots.txt (wires a [RobotsCache] backed by an IO fetcher).
  final bool respectRobots;

  bool get hasContextDefaults =>
      userAgent != null ||
      locale != null ||
      timezone != null ||
      viewport != null;
}

/// A [ContextRegistry] that fills unset context-identity fields (userAgent /
/// viewport / locale / timezone) from the host's [BrowserEngineConfig]. The
/// mcp_browser operations only set tenantId/actorId on the spec, so this is
/// the host-side injection point for engine-wide browser identity — no
/// package change needed (acquire is a plain overridable method).
class _DefaultSpecContextRegistry extends ContextRegistry {
  _DefaultSpecContextRegistry({
    required super.engines,
    required super.policy,
    required this.config,
  });

  final BrowserEngineConfig config;

  @override
  Future<BrowserContextHandle> acquire(BrowserContextSpec spec) {
    return super.acquire(
      BrowserContextSpec(
        tenantId: spec.tenantId,
        actorId: spec.actorId,
        engineId: spec.engineId,
        persistent: spec.persistent,
        viewport: spec.viewport ?? config.viewport,
        locale: spec.locale ?? config.locale,
        timezone: spec.timezone ?? config.timezone,
        geolocation: spec.geolocation,
        userAgent: spec.userAgent ?? config.userAgent,
      ),
    );
  }
}

/// Minimal [RobotsFetcher] — GETs `<origin>/robots.txt` over `dart:io`. host
/// supplies this so `respectRobots` works (mcp_browser declares the interface
/// but ships no implementation).
class _IoRobotsFetcher implements RobotsFetcher {
  final HttpClient _client = HttpClient();

  @override
  Future<String?> fetch(String origin) async {
    try {
      final req = await _client.getUrl(Uri.parse('$origin/robots.txt'));
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      return await resp.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    }
  }
}

/// Lazily boots (and re-boots on path change) a `mcp_browser`
/// [BrowserOperations] from the host's Chromium path. Mirrors ops'
/// former `BrowserAdapter.fromConfig`, lifted to the host so the engine
/// is shared rather than ops-owned.
class _LazyBrowserEngine {
  _LazyBrowserEngine(
    this._chromiumPath,
    this._authStore,
    this._config, {
    bool headless = true,
  }) : _headless = headless;

  final String? Function() _chromiumPath;
  final SealedAuthProfileStore? _authStore;

  /// Host-owned engine config (caps / identity / robots). Null = defaults.
  final BrowserEngineConfig Function()? _config;

  /// Headless for the scraping ops; the auth-capture engine runs headful so
  /// the user can complete an interactive login (adapt-browser.md §7).
  final bool _headless;

  String? _bootedPath;
  BrowserRuntime? _runtime;
  BrowserOperations? _operations;
  Future<BrowserOperations?>? _booting;

  /// The booted runtime, or null when disabled (no Chromium path). Boots
  /// on demand like [operations]; used by auth capture to reach the
  /// context registry + context port for a storage-state snapshot.
  Future<BrowserRuntime?> runtimeOrNull() async {
    await operations();
    return _runtime;
  }

  Future<BrowserOperations?> operations() {
    final path = _chromiumPath();
    if (path == null || path.isEmpty) {
      return Future<BrowserOperations?>.value(null);
    }
    if (_operations != null && _bootedPath == path) {
      return Future<BrowserOperations?>.value(_operations);
    }
    // Coalesce concurrent first-calls onto one boot; a path change
    // supersedes an in-flight boot for a stale path.
    final inFlight = _booting;
    if (inFlight != null && _bootedPath == path) return inFlight;
    return _booting = _boot(path);
  }

  Future<BrowserOperations?> _boot(String path) async {
    await _runtime?.shutdown();
    final cfg = _config?.call() ?? const BrowserEngineConfig();
    // Robots enforcement (host-supplied fetcher) + concurrent-context cap.
    final policy = PolicyEngine.defaults(
      robots:
          cfg.respectRobots ? RobotsCache(fetcher: _IoRobotsFetcher()) : null,
    );
    final maxCtx = cfg.maxConcurrentContexts;
    if (maxCtx != null && maxCtx > 0) {
      policy.resourceCaps = BrowserResourceCaps(maxConcurrentContexts: maxCtx);
    }
    final audit = AuditTrail(sink: InMemoryAuditSink());
    final launcher = ChromiumLauncher(
      executablePath: path,
      headless: _headless,
    );
    final connection = CdpConnection(launcher: launcher);
    final context = CdpContextPort(connection: connection);
    final engine = CdpEngine(connection: connection);
    final engines =
        EngineRegistry()..register('cdp', engine: engine, context: context);
    // Use the default-spec registry so engine-wide browser identity
    // (userAgent / viewport / locale / timezone) is applied to every context.
    final contexts =
        cfg.hasContextDefaults
            ? _DefaultSpecContextRegistry(
              engines: engines,
              policy: policy,
              config: cfg,
            )
            : ContextRegistry(engines: engines, policy: policy);
    final search =
        SearchRouter()
          ..register('ddg', DuckDuckGoSearchAdapter(fetcher: IoHttpFetcher()));
    final runtime = BrowserRuntime(
      engines: engines,
      contexts: contexts,
      policy: policy,
      audit: audit,
      search: search,
      authStore: _authStore,
    );
    final operations = BrowserOperations(runtime: runtime, contexts: contexts);
    await runtime.initialize();
    _runtime = runtime;
    _operations = operations;
    _bootedPath = path;
    _booting = null;
    return operations;
  }
}

/// `BrowserAuthProfilePort` backed by [AtRestSealer]-sealed `.enc` files.
///
/// One host-owned store serves both ends of the auth round-trip:
///   - `browser.auth_capture` calls [put] to seal a freshly captured
///     profile, and
///   - `BrowserRuntime`'s `setAuth` calls [get] to decrypt and re-inject
///     it into a live context.
/// Profiles live at `<root>/<tenantId>/<id>.enc`; the seal `context` binds
/// each blob to `auth/<tenantId>/<id>` (AEAD AAD) so a blob cannot be
/// renamed onto another identity. [rootDir] is read fresh so the location
/// can follow a settings / workspace change.
class SealedAuthProfileStore implements BrowserAuthProfilePort {
  SealedAuthProfileStore({required this.sealer, required this.rootDir});

  final AtRestSealer sealer;
  final String? Function() rootDir;

  /// Decrypted cache, keyed `<tenantId>/<id>`.
  final Map<String, BrowserAuthProfile> _hot = <String, BrowserAuthProfile>{};

  String _hotKey(String tenantId, String id) => '$tenantId/$id';
  String _context(String tenantId, String id) => 'auth/$tenantId/$id';

  String _root() {
    final r = rootDir();
    if (r == null || r.isEmpty) {
      throw StateError('SealedAuthProfileStore: auth root not configured');
    }
    return r;
  }

  /// Reject identifiers that could escape the auth root (path traversal)
  /// or break the `<root>/<tenant>/<id>.enc` layout. `tenantId` / `id`
  /// originate from MCP args, so this is the security boundary.
  static String _safeSegment(String value, String label) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains(r'\') ||
        value.contains(' ')) {
      throw ArgumentError.value(value, label, 'invalid path segment');
    }
    return value;
  }

  File _file(String tenantId, String id) => File(
    p.join(
      _root(),
      _safeSegment(tenantId, 'tenantId'),
      '${_safeSegment(id, 'id')}.enc',
    ),
  );

  /// Seal [profile] and write it. Returns the `.enc` path. (Widens the
  /// port's `Future<void> put` return so the capture tool can report the
  /// path; callers expecting `void` are unaffected.)
  @override
  Future<String> put(BrowserAuthProfile profile) async {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(profile.toJson())));
    final sealed = await sealer.sealBytes(
      plain,
      context: _context(profile.tenantId, profile.id),
    );
    final file = _file(profile.tenantId, profile.id);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(sealed, flush: true);
    _hot[_hotKey(profile.tenantId, profile.id)] = profile;
    return file.path;
  }

  @override
  Future<BrowserAuthProfile?> get(String tenantId, String id) async {
    final cached = _hot[_hotKey(tenantId, id)];
    if (cached != null) return cached;
    try {
      // _file validates the segments (throws ArgumentError on a traversal
      // attempt); catching here yields null per the port contract.
      final file = _file(tenantId, id);
      if (!await file.exists()) return null;
      final sealed = Uint8List.fromList(await file.readAsBytes());
      final plain = await sealer.openBytes(
        sealed,
        context: _context(tenantId, id),
      );
      final json = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(plain)) as Map,
      );
      final profile = BrowserAuthProfile.fromJson(json);
      _hot[_hotKey(tenantId, id)] = profile;
      return profile;
    } catch (_) {
      // Tamper / wrong key / corrupt payload → null per port contract.
      return null;
    }
  }

  @override
  Future<void> delete(String tenantId, String id) async {
    _hot.remove(_hotKey(tenantId, id));
    try {
      final file = _file(tenantId, id);
      if (await file.exists()) await file.delete();
    } on ArgumentError {
      // Unsafe identity → nothing to delete.
    }
  }

  @override
  Future<List<BrowserAuthProfileMeta>> list(String tenantId) async {
    final Directory dir;
    try {
      dir = Directory(p.join(_root(), _safeSegment(tenantId, 'tenantId')));
    } on ArgumentError {
      return const <BrowserAuthProfileMeta>[];
    }
    if (!await dir.exists()) return const <BrowserAuthProfileMeta>[];
    final out = <BrowserAuthProfileMeta>[];
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.enc')) {
        final id = p.basenameWithoutExtension(entry.path);
        final profile = await get(tenantId, id);
        if (profile != null) {
          out.add(BrowserAuthProfileMeta.fromProfile(profile));
        }
      }
    }
    return out;
  }

  @override
  Future<bool> isExpired(String tenantId, String id) async {
    final profile = await get(tenantId, id);
    if (profile == null) return false;
    return profile.isExpiredAt(DateTime.now());
  }

  @override
  Future<BrowserAuthProfile> refreshProfile(String tenantId, String id) async {
    // Captured profiles carry no refresh callback (not persisted). The
    // re-capture path is `browser.auth_capture`, not an automatic refresh.
    throw StateError(
      'SealedAuthProfileStore: refresh unsupported — re-capture via '
      'browser.auth_capture',
    );
  }
}
