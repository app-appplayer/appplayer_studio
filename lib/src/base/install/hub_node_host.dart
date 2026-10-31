/// Hub node host — the expose direction: the host's own tool surface becomes
/// a node on the market hub, so a caller the market vouches for (the signed-in
/// user's remote LLM, or Arche holding a grant the user handed over) can drive
/// this machine through ordinary MCP.
///
/// The node dials OUT to the relay (NAT is no obstacle), is registered once
/// under the user's market identity, and believes only the market-signed
/// caller token on each session's `open` (spec platform/15, market DDD
/// `09-service-access` §8-4). What the caller may reach is the hub's access
/// scope plus this host's [HubNodePolicy]; the host adds no second login.
///
/// Host wiring only: relay frames and caller verification live in the vendored
/// `gateway_node` recipe; the market doors, the token store and the tool
/// surface are injected so Studio, Pro and the workbench share one node.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mcp_gateway/mcp_gateway.dart';

import 'gateway_node/gateway_node.dart';
import 'hub_connections.dart' show HubConnectionError;
import 'market_app_check.dart' show marketIdentityHeaders;

/// What the market issues when a node is registered.
class HubNodeRegistration {
  const HubNodeRegistration({
    required this.id,
    required this.relayToken,
    required this.relayTokenExpiresAt,
    required this.relayUrl,
  });

  factory HubNodeRegistration.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final token = json['relayToken'];
    final url = json['relayUrl'];
    if (id is! String || token is! String || url is! String) {
      throw const FormatException(
        'node registration lacks id / relayToken / relayUrl',
      );
    }
    return HubNodeRegistration(
      id: id,
      relayToken: token,
      relayTokenExpiresAt: (json['relayTokenExpiresAt'] as num?)?.toInt() ?? 0,
      relayUrl: url,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'relayToken': relayToken,
    'relayTokenExpiresAt': relayTokenExpiresAt,
    'relayUrl': relayUrl,
  };

  final String id;
  final String relayToken;

  /// Epoch milliseconds; 0 = unknown (treated as not expiring).
  final int relayTokenExpiresAt;
  final String relayUrl;

  bool expiresWithin(Duration margin, DateTime now) =>
      relayTokenExpiresAt > 0 &&
      now.millisecondsSinceEpoch + margin.inMilliseconds >= relayTokenExpiresAt;
}

/// The market's node doors (hub/control and the listing door).
abstract class HubNodePort {
  /// `POST /hub/nodes` — register this host as a node.
  Future<HubNodeRegistration> register();

  /// `POST /hub/nodes/:id/rotate-token` — replace the relay secret.
  Future<HubNodeRegistration> rotate(HubNodeRegistration current);

  /// `DELETE /hub/nodes/:id` — remove the node; its open sessions close.
  Future<void> remove(String nodeId);

  /// The market's public caller-token keys (`GET /market/hub/caller-jwks`,
  /// no login). A token names its key by `kid`.
  Future<List<HubCallerKey>> callerKeys();
}

/// One Ed25519 key the market signs caller tokens with.
class HubCallerKey {
  const HubCallerKey({required this.kid, required this.x});

  final String kid;

  /// base64url raw 32-byte public key (JWK `x`).
  final String x;
}

/// Verifies caller tokens against the market's published keys. The token's
/// `kid` picks the key; an unknown `kid` refetches the list (a rotation), at
/// most once per [refetchEvery] so garbage tokens cannot hammer the market. A
/// token with no `kid` (issued before keys carried one) is tried against every
/// known key.
HubCallerVerifier jwksCallerVerifier({
  required Future<List<HubCallerKey>> Function() fetch,
  required String nodeId,
  DateTime Function()? now,
  Duration refetchEvery = const Duration(seconds: 30),
}) {
  final clock = now ?? DateTime.now;
  final byKid = <String, HubCallerVerifier>{};
  DateTime? fetchedAt;

  Future<void> reload() async {
    final keys = await fetch();
    fetchedAt = clock();
    byKid
      ..clear()
      ..addEntries([
        for (final k in keys)
          MapEntry(
            k.kid,
            marketHubCallerVerifier(
              publicKeyPem: ed25519PemFromJwkX(k.x),
              nodeId: nodeId,
              now: now,
            ),
          ),
      ]);
  }

  Future<void> reloadIfDue() async {
    final at = fetchedAt;
    if (at == null || clock().difference(at) >= refetchEvery) await reload();
  }

  String? kidOf(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final header = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
      );
      final kid = header is Map ? header['kid'] : null;
      return kid is String && kid.isNotEmpty ? kid : null;
    } catch (_) {
      return null;
    }
  }

  return (token) async {
    if (byKid.isEmpty) await reloadIfDue();
    final kid = kidOf(token);
    if (kid != null) {
      var v = byKid[kid];
      if (v == null) {
        await reloadIfDue();
        v = byKid[kid];
      }
      return v?.call(token);
    }
    for (final v in byKid.values) {
      final caller = await v(token);
      if (caller != null) return caller;
    }
    return null;
  };
}

/// Persists the node registration. The relay token is a secret: a host keeps
/// it in its credential vault, never in a plain file.
abstract class HubNodeStore {
  Future<HubNodeRegistration?> load();
  Future<void> save(HubNodeRegistration registration);
  Future<void> clear();
}

/// The tools this host serves to a remote caller.
abstract class LocalToolSurface {
  Future<List<ToolDefinition>> list();
  Future<DispatchResult> call(String name, Map<String, dynamic> arguments);
}

/// What a verified caller may do on top of the hub's access scope.
class HubNodePolicy {
  const HubNodePolicy({this.denied = const <String>{}, this.approve});

  /// Tool names never served to a remote caller.
  final Set<String> denied;

  /// Optional human gate for a call. Null = the hub scope alone decides (the
  /// default: the user opening the session is the authorisation). A host may
  /// require approval for risky tools through its own UI; no answer = refusal.
  final Future<bool> Function(
    HubCaller caller,
    String tool,
    Map<String, dynamic> arguments,
  )?
  approve;
}

enum HubNodeState {
  stopped,
  registering,
  connecting,
  online,
  reconnecting,
  failed,
}

/// The relay node socket as the host sees it.
class HubNodeChannel {
  const HubNodeChannel({
    required this.envelopes,
    required this.send,
    required this.close,
    required this.done,
  });

  final Stream<Map<String, dynamic>> envelopes;
  final Future<void> Function(Map<String, dynamic> envelope) send;
  final Future<void> Function() close;
  final Future<void> done;
}

typedef HubNodeChannelOpener =
    Future<HubNodeChannel> Function(HubNodeRegistration registration);

/// The production opener: the relay's `role=node` socket.
Future<HubNodeChannel> openRelayNodeChannel(
  HubNodeRegistration registration,
) async {
  final socket = await RelaySocket.node(
    relayUrl: registration.relayUrl,
    nodeId: registration.id,
    relayToken: registration.relayToken,
  );
  return HubNodeChannel(
    envelopes: socket.nodeEnvelopes,
    send: socket.sendEnvelope,
    close: socket.close,
    done: socket.done,
  );
}

class HubNodeHost {
  HubNodeHost({
    required this.port,
    required this.store,
    required this.tools,
    this.policy = const HubNodePolicy(),
    this.open = openRelayNodeChannel,
    this.providerId = 'host',
    this.ownerSubject,
    this.rotateMargin = const Duration(days: 7),
    this.backoffStart = const Duration(seconds: 1),
    this.backoffMax = const Duration(seconds: 30),
    this.stableAfter = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final HubNodePort port;
  final HubNodeStore store;
  final LocalToolSurface tools;
  final HubNodePolicy policy;
  final HubNodeChannelOpener open;

  /// Prefix of the provider's tools as callers see them (`host.<tool>`).
  final String providerId;

  /// When set, only a caller whose `sub` is this market uid is let in — the
  /// node's own check on top of the market's owner-only scope.
  final String? ownerSubject;

  /// Rotate the relay token when it expires within this margin.
  final Duration rotateMargin;
  final Duration backoffStart;
  final Duration backoffMax;

  /// A relay socket that stays up this long counts as a healthy connection;
  /// one that closes sooner is a failed attempt, so the wait before the next
  /// dial keeps growing instead of starting over.
  final Duration stableAfter;
  final DateTime Function() _now;

  final StreamController<HubNodeState> _states =
      StreamController<HubNodeState>.broadcast();
  HubNodeState _state = HubNodeState.stopped;
  String? _error;
  HubNodeRegistration? _registration;

  GatewayRuntime? _runtime;
  GatewayClientAdapter? _provider;
  HubRelayNodeServer? _server;
  HubNodeChannel? _channel;
  HubCallerVerifier? _verify;
  bool _wanted = false;
  int _gen = 0;

  HubNodeState get state => _state;
  String? get error => _error;
  String? get nodeId => _registration?.id;
  Stream<HubNodeState> get states => _states.stream;

  HubNodeDirectory? get _directory {
    final p = port;
    return p is HubNodeDirectory ? p as HubNodeDirectory : null;
  }

  /// The account's nodes on this hub, as the hub reports them; empty when the
  /// port cannot list.
  Future<List<HubNodeInfo>> nodes() async =>
      await _directory?.list() ?? const <HubNodeInfo>[];

  /// Takes a node of this account off the hub.
  Future<void> releaseNode(String nodeId) async {
    await _directory?.release(nodeId);
  }

  /// Sets how often the hub checks this machine's node (0 = never).
  Future<void> setHeartbeat(int seconds) async {
    final id = nodeId;
    if (id != null) await _directory?.setHeartbeat(id, seconds);
  }

  /// Verified callers with an open session, by session id.
  Set<String> get sessions => _server?.sessions ?? const <String>{};
  HubCaller? callerOf(String sessionId) => _server?.callerOf(sessionId);

  void _set(HubNodeState s, [String? error]) {
    _state = s;
    _error = error;
    if (!_states.isClosed) _states.add(s);
  }

  /// Register (once), publish the listing, and go online. Idempotent.
  Future<void> start() async {
    if (_wanted) return;
    _wanted = true;
    final gen = ++_gen;
    try {
      _set(HubNodeState.registering);
      var reg = await store.load();
      if (reg == null) {
        reg = await port.register();
        await store.save(reg);
      } else if (reg.expiresWithin(rotateMargin, _now())) {
        reg = await port.rotate(reg);
        await store.save(reg);
      }
      _registration = reg;
      // A node never opens without a way to check who is calling: fetch the
      // market's caller keys now, and fail loudly when there are none.
      final keys = await port.callerKeys();
      if (keys.isEmpty) {
        throw const HubConnectionError(
          'hub.caller_key_unavailable',
          'the market published no caller-token key',
        );
      }
      final verifyToken = jwksCallerVerifier(
        fetch: port.callerKeys,
        nodeId: reg.id,
        now: _now,
      );
      final owner = ownerSubject;
      _verify =
          owner == null
              ? verifyToken
              : (token) async {
                final caller = await verifyToken(token);
                return caller != null && caller.subject == owner
                    ? caller
                    : null;
              };
      await _bringUpRuntime();
      // Return after the first dial attempt; a relay that is down keeps
      // retrying in the background instead of holding the caller.
      final first = Completer<void>();
      unawaited(_connect(gen, first));
      await first.future;
    } catch (e) {
      _wanted = false;
      _set(HubNodeState.failed, '$e');
      rethrow;
    }
  }

  /// Re-publish the tool list after the host's surface changed.
  Future<void> refreshTools() async {
    if (_runtime == null) return;
    await _provider?.unregister();
    await _bringUpProvider();
  }

  /// Go offline. The registration stays so the next start reuses it.
  Future<void> stop() async {
    _wanted = false;
    _gen++;
    await _tearDownConnection();
    await _provider?.unregister();
    _provider = null;
    _runtime?.dispose();
    _runtime = null;
    _set(HubNodeState.stopped);
  }

  /// Take the node off the market entirely (sessions close, token dies).
  Future<void> unregister() async {
    final reg = _registration ?? await store.load();
    await stop();
    if (reg != null) await port.remove(reg.id);
    await store.clear();
    _registration = null;
  }

  Future<void> dispose() async {
    await stop();
    await _states.close();
  }

  Future<void> _bringUpRuntime() async {
    final runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();
    _runtime = runtime;
    await _bringUpProvider();
  }

  Future<void> _bringUpProvider() async {
    final runtime = _runtime!;
    final defs = await tools.list();
    final provider = GatewayClientAdapter(runtime)..onDispatch = _dispatch;
    await provider.register(
      ProviderRegistration(
        providerId: providerId,
        schemaVersion: DateTime.now().millisecondsSinceEpoch,
        schema: ProviderSchemaBody(
          tools: [
            for (final d in defs)
              if (!policy.denied.contains(d.name)) d,
          ],
        ),
      ),
    );
    unawaited(provider.startPollLoop());
    _provider = provider;
  }

  Future<DispatchResult> _dispatch(DispatchPayload d) async {
    if (d.method != 'tools/call') {
      return DispatchResult(
        content: [_text('${d.method} is not served by this node (tools only)')],
        isError: true,
      );
    }
    final name = d.params['name'];
    final args =
        (d.params['arguments'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    if (name is! String) {
      return DispatchResult(
        content: [_text('tool name is required')],
        isError: true,
      );
    }
    if (policy.denied.contains(name)) {
      return DispatchResult(
        content: [_text('$name is not served to remote callers')],
        isError: true,
      );
    }
    final gate = policy.approve;
    if (gate != null) {
      final caller = d.consumerId == null ? null : callerOf(d.consumerId!);
      if (caller == null || !await gate(caller, name, args)) {
        return DispatchResult(
          content: [_text('$name was not approved on this machine')],
          isError: true,
        );
      }
    }
    try {
      return await tools.call(name, args);
    } catch (e) {
      return DispatchResult(
        content: [_text('$name failed: $e')],
        isError: true,
      );
    }
  }

  Map<String, dynamic> _text(String t) => {'type': 'text', 'text': t};

  DateTime? _upAt;
  late Duration _lap = backoffStart;

  Future<void> _connect(int gen, [Completer<void>? first]) async {
    var wait = backoffStart;
    while (_wanted && gen == _gen) {
      try {
        _set(
          _state == HubNodeState.reconnecting
              ? HubNodeState.reconnecting
              : HubNodeState.connecting,
        );
        var reg = _registration!;
        if (reg.expiresWithin(rotateMargin, _now())) {
          reg = await port.rotate(reg);
          await store.save(reg);
          _registration = reg;
        }
        final channel = await open(reg);
        _channel = channel;
        final server = HubRelayNodeServer(
          runtime: _runtime!,
          incoming: channel.envelopes,
          send: channel.send,
          verifyCaller: _verify!,
          now: _now,
        );
        await server.start();
        _server = server;
        _set(HubNodeState.online);
        _upAt = _now();
        unawaited(
          channel.done.then(
            (_) => _dropped(gen, 'relay closed'),
            onError: (Object e) => _dropped(gen, 'relay error: $e'),
          ),
        );
        if (first != null && !first.isCompleted) first.complete();
        return;
      } catch (e) {
        _set(HubNodeState.reconnecting, '$e');
        if (first != null && !first.isCompleted) first.complete();
        await Future<void>.delayed(wait);
        wait = Duration(
          milliseconds: (wait.inMilliseconds * 2).clamp(
            backoffStart.inMilliseconds,
            backoffMax.inMilliseconds,
          ),
        );
      }
    }
    if (first != null && !first.isCompleted) first.complete();
  }

  void _dropped(int gen, String reason) {
    if (!_wanted || gen != _gen) return;
    unawaited(() async {
      await _server?.stop();
      _server = null;
      _channel = null;
      _set(HubNodeState.reconnecting, reason);
      final up = _upAt == null ? Duration.zero : _now().difference(_upAt!);
      if (up >= stableAfter) {
        _lap = backoffStart;
      } else {
        await Future<void>.delayed(_lap);
        _lap = Duration(
          milliseconds: (_lap.inMilliseconds * 2).clamp(
            backoffStart.inMilliseconds,
            backoffMax.inMilliseconds,
          ),
        );
      }
      if (!_wanted || gen != _gen) return;
      await _connect(gen);
    }());
  }

  Future<void> _tearDownConnection() async {
    await _server?.stop();
    _server = null;
    final channel = _channel;
    _channel = null;
    try {
      await channel?.close();
    } catch (_) {}
  }
}

/// The state of a node the hub knows (platform spec 15 §4-1): its socket is
/// held (connected), it is not held right now (disconnected) or it was closed
/// on purpose (closed).
enum HubNodeLinkState { connected, disconnected, closed }

/// One node of the signed-in account on a hub.
class HubNodeInfo {
  const HubNodeInfo({
    required this.id,
    required this.state,
    this.deployment,
    this.hint,
    this.heartbeatSec = 0,
  });

  final String id;
  final HubNodeLinkState state;

  /// Where it runs (local · cloud · embedded).
  final String? deployment;

  /// The name its owner gave it.
  final String? hint;

  /// How often the hub checks its connection, in seconds; 0 = never.
  final int heartbeatSec;

  static HubNodeInfo? fromJson(Object? row) {
    if (row is! Map || row['id'] is! String) return null;
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    final state = switch (row['state']) {
      'connected' => HubNodeLinkState.connected,
      'closed' => HubNodeLinkState.closed,
      _ => HubNodeLinkState.disconnected,
    };
    return HubNodeInfo(
      id: row['id'] as String,
      state: state,
      deployment: text(row['deployment']),
      hint: text(row['endpointHint']),
      heartbeatSec:
          row['heartbeatSec'] is num ? (row['heartbeatSec'] as num).toInt() : 0,
    );
  }
}

/// A port that can also list and manage the account's nodes on its hub.
abstract class HubNodeDirectory {
  Future<List<HubNodeInfo>> list();

  /// Takes a node off the hub; its open sessions close with it.
  Future<void> release(String nodeId);

  /// How often the hub checks one node's connection; 0 turns the check off.
  Future<void> setHeartbeat(String nodeId, int seconds);
}

/// [HubNodePort] over the market's HTTP API with the signed-in user's token.
class HttpHubNodePort implements HubNodePort, HubNodeDirectory {
  HttpHubNodePort({
    required this.baseUrl,
    this.hubBaseUrl,
    required this.token,
    this.appCheckToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Market API root (listing door).
  final String baseUrl;

  /// Hub control root (`/hub/nodes`). When null, the signed-in account's own
  /// hub address is asked of the market once (`GET /market/me/hub`).
  final String? hubBaseUrl;
  final Future<String?> Function() token;

  /// App Check token of this app; the market refuses calls without it. Sent
  /// to the market origin only, never to another hub's control address.
  final Future<String?> Function()? appCheckToken;

  final http.Client _client;
  String? _control;

  /// The hub address the market itself returned for this account — the
  /// market's own hub, so the market login may be sent there even though its
  /// origin differs from the API root (platform spec 15 §10.1: one hub, one
  /// address for everyone, `GET /market/me/hub`).
  String? _marketHub;

  Future<String> _controlRoot() async {
    final fixed = hubBaseUrl ?? _control;
    if (fixed != null) return fixed;
    final r = await _client.get(
      Uri.parse('$baseUrl/market/me/hub'),
      headers: await _headers(),
    );
    final hub = _decode(r)['hub'];
    final control = hub is Map ? hub['control'] : null;
    if (control is! String || control.isEmpty) {
      throw const HubConnectionError(
        'hub.address_unavailable',
        'the market returned no hub address',
      );
    }
    _marketHub = control;
    return _control = control;
  }

  Future<Map<String, String>> _headers([String? root]) async {
    final t = await token();
    if (t == null || t.isEmpty) {
      throw const HubConnectionError(
        'hub.not_signed_in',
        'sign in to the market before exposing this machine',
      );
    }
    final sameOrigin =
        root == null || Uri.parse(root).origin == Uri.parse(baseUrl).origin;
    final marketHub = _marketHub;
    final marketsOwnHub =
        root != null &&
        marketHub != null &&
        Uri.parse(root).origin == Uri.parse(marketHub).origin;
    // The market login token goes to the market's own hub only: the API root,
    // or the address the market returned for this account. A hub address that
    // came from anywhere else (a service's own hub) never gets it.
    if (!sameOrigin && !marketsOwnHub) {
      throw HubConnectionError(
        'hub.control_foreign',
        'this hub is not served by the market ($root); the market login is not sent there',
      );
    }
    final headers = {
      'authorization': 'Bearer $t',
      'content-type': 'application/json',
      ...marketIdentityHeaders(),
    };
    final check = sameOrigin ? await appCheckToken?.call() : null;
    if (check != null && check.isNotEmpty)
      headers['X-Firebase-AppCheck'] = check;
    return headers;
  }

  Map<String, dynamic> _decode(http.Response r) {
    final ok = r.statusCode >= 200 && r.statusCode < 300;
    Object? json;
    try {
      json = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body);
    } on FormatException {
      if (ok) rethrow;
    }
    if (!ok) {
      final err = json is Map ? json['error'] : null;
      final message =
          err is Map
              ? err['message']
              : (err is String ? err : (json is Map ? json['message'] : null));
      throw HubConnectionError(
        'hub.market_${r.statusCode}',
        '${message ?? (json == null && r.body.isNotEmpty ? r.body : 'market error')}',
      );
    }
    return (json as Map).cast<String, dynamic>();
  }

  @override
  Future<HubNodeRegistration> register() async {
    final root = await _controlRoot();
    final r = await _client.post(
      Uri.parse('$root/hub/nodes'),
      headers: await _headers(root),
      body: jsonEncode(<String, dynamic>{'deployment': 'local'}),
    );
    return HubNodeRegistration.fromJson(_decode(r));
  }

  @override
  Future<HubNodeRegistration> rotate(HubNodeRegistration current) async {
    final root = await _controlRoot();
    final r = await _client.post(
      Uri.parse('$root/hub/nodes/${current.id}/rotate-token'),
      headers: await _headers(root),
    );
    final j = _decode(r);
    return HubNodeRegistration(
      id: current.id,
      relayToken: j['relayToken'] as String,
      relayTokenExpiresAt: (j['relayTokenExpiresAt'] as num?)?.toInt() ?? 0,
      relayUrl: current.relayUrl,
    );
  }

  @override
  Future<void> remove(String nodeId) async {
    final root = await _controlRoot();
    _decode(
      await _client.delete(
        Uri.parse('$root/hub/nodes/$nodeId'),
        headers: await _headers(root),
      ),
    );
  }

  @override
  Future<List<HubNodeInfo>> list() async {
    final root = await _controlRoot();
    final r = await _client.get(
      Uri.parse('$root/hub/nodes'),
      headers: await _headers(root),
    );
    return [
      for (final row in (_decode(r)['nodes'] as List? ?? const []))
        if (HubNodeInfo.fromJson(row) case final HubNodeInfo n) n,
    ];
  }

  @override
  Future<void> release(String nodeId) => remove(nodeId);

  @override
  Future<void> setHeartbeat(String nodeId, int seconds) async {
    final root = await _controlRoot();
    _decode(
      await _client.put(
        Uri.parse('$root/hub/nodes/${Uri.encodeComponent(nodeId)}/heartbeat'),
        headers: await _headers(root),
        body: jsonEncode({'heartbeatSec': seconds}),
      ),
    );
  }

  @override
  Future<List<HubCallerKey>> callerKeys() async {
    final r = await _client.get(Uri.parse('$baseUrl/market/hub/caller-jwks'));
    return [
      for (final k in (_decode(r)['keys'] as List? ?? const []))
        if (k is Map && k['x'] is String && k['kid'] is String)
          HubCallerKey(kid: k['kid'] as String, x: k['x'] as String),
    ];
  }
}

/// Ed25519 SPKI PEM from a JWK `x` (base64url raw key) — for a market door
/// that serves the caller-token key as a JWKS entry.
String ed25519PemFromJwkX(String x) {
  final raw = base64Url.decode(base64Url.normalize(x));
  if (raw.length != 32) {
    throw ArgumentError.value(x, 'x', 'not a 32-byte Ed25519 public key');
  }
  final der = Uint8List.fromList(<int>[
    0x30,
    0x2a,
    0x30,
    0x05,
    0x06,
    0x03,
    0x2b,
    0x65,
    0x70,
    0x03,
    0x21,
    0x00,
    ...raw,
  ]);
  return '-----BEGIN PUBLIC KEY-----\n${base64.encode(der)}\n-----END PUBLIC KEY-----';
}
