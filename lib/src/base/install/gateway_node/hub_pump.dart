import 'dart:async';

import 'package:mcp_gateway/mcp_gateway.dart';

/// Hub pump — drives the `mcp_gateway` dispatch protocol across a hub relay
/// (spec 15 §8 "gateway binding"), **entirely over `mcp_gateway`'s public
/// surface — the core package is unchanged**.
///
/// The topology is a reverse tunnel: both endpoints dial OUT to the cloud hub
/// relay (a raw MCP-frame pipe), yet the tool-*providing* node is the one that
/// dials out and serves incoming calls (an MCP server that connects as a
/// client). So the wire carries the gateway dispatch protocol — request/result
/// + event — not raw MCP JSON-RPC.
///
/// - [HubGatewayProvider] bridges a started [GatewayRuntime] to the relay:
///   incoming request frames feed `runtime.handleConsumerRequest` /
///   `getFilteredConsumerToolList` / `eventBus.subscribe`; outgoing events ride
///   `runtime.eventBus.onEventRelay`. **The exact public entry points** the
///   package exposes (and `GatewayServerAdapter` itself uses `onEventRelay`), so
///   no core seam is added.
/// - [HubGatewayConsumer] is the other end: a plain frame client that lists /
///   calls tools and receives events over the relay. It needs no runtime.
///
/// The transport is injected as an `(incoming, send)` pair — the host wires its
/// firestore data-plane or ws relay (spec 15 §4). Use [HubMemoryTransport] for
/// tests / local wiring.

/// Wire frame keys for the hub pump (opaque `payload` per spec 15 §3). Single
/// source of truth shared by [HubGatewayProvider] and [HubGatewayConsumer].
class HubWire {
  HubWire._();

  static const kind = 'k';
  static const id = 'id';
  static const method = 'method';
  static const params = 'params';
  static const ok = 'ok';
  static const result = 'result';

  // kinds
  static const req = 'req';
  static const res = 'res';
  static const event = 'event';

  // methods
  static const toolsList = 'tools/list';
  static const toolsCall = 'tools/call';
  static const subscribe = 'subscribe';
  static const unsubscribe = 'unsubscribe';
  // Full-MCP verbs (mcp_gateway 0.1.1 표준 준수 확장) — 허브 경유 UI 서빙의
  // 프로토콜 절반. resources/read 만으로 ui://app · ui://pages/* 가 성립한다.
  static const resourcesList = 'resources/list';
  static const resourcesRead = 'resources/read';
  static const resourcesTemplatesList = 'resources/templates/list';
  static const resourcesSubscribe = 'resources/subscribe';
  static const resourcesUnsubscribe = 'resources/unsubscribe';
  static const promptsList = 'prompts/list';
  static const promptsGet = 'prompts/get';

  // result / event fields
  static const tools = 'tools';
  static const content = 'content';
  static const isError = 'isError';
  static const error = 'error';
  static const providerId = 'providerId';
  static const eventType = 'eventType';
  static const payload = 'payload';
  static const eventTypes = 'eventTypes';
  static const name = 'name';
  static const arguments = 'arguments';
  static const resources = 'resources';
  static const resourceTemplates = 'resourceTemplates';
  static const prompts = 'prompts';
  static const uri = 'uri';
}

/// Result of [HubGatewayConsumer.callTool] — the MCP tool content + error flag.
typedef HubCallResult = ({List<Map<String, dynamic>> content, bool isError});

/// Handle one inbound request frame against [runtime] as [consumerId] and return
/// the response frame (`null` if [frame] is not a request). Shared by the
/// single-session [HubGatewayProvider] and the multiplexed node server so the
/// verb translation (tools/list · tools/call · subscribe) lives in one place.
Future<Map<String, dynamic>?> handleHubRequest(
  GatewayRuntime runtime,
  String consumerId,
  Map<String, dynamic> frame,
) async {
  if (frame[HubWire.kind] != HubWire.req) return null;
  final id = frame[HubWire.id];
  final method = frame[HubWire.method] as String?;
  final params =
      (frame[HubWire.params] as Map?)?.cast<String, dynamic>() ?? const {};
  try {
    switch (method) {
      case HubWire.toolsList:
        final tools =
            runtime
                .getFilteredConsumerToolList(consumerId)
                .map((t) => t.toJson())
                .toList();
        return _resFrame(id, {HubWire.tools: tools});
      case HubWire.toolsCall:
        final r = await runtime.handleConsumerRequest(
          consumerId,
          'tools/call',
          params,
        );
        return _resFrame(id, {
          HubWire.content: r.content ?? const <Map<String, dynamic>>[],
          HubWire.isError: r.isError,
        });
      case HubWire.subscribe:
        await runtime.eventBus.subscribe(
          consumerId,
          params[HubWire.providerId] as String,
          (params[HubWire.eventTypes] as List?)?.cast<String>() ?? const [],
        );
        return _resFrame(id, const {});
      case HubWire.unsubscribe:
        await runtime.eventBus.unsubscribe(
          consumerId,
          params[HubWire.providerId] as String,
        );
        return _resFrame(id, const {});
      // ── full-MCP surface (0.1.1) — URIs/이름은 재작성하지 않는다(패키지 계약:
      // 원 URI 보존, 출처는 _gateway 메타). read/subscribe/get 은 소유 provider
      // 라우팅을 runtime.handleConsumerRequest 가 수행한다.
      case HubWire.resourcesList:
        final resources =
            runtime
                .getFilteredConsumerResourceList(consumerId)
                .map((r) => r.toJson())
                .toList();
        return _resFrame(id, {HubWire.resources: resources});
      case HubWire.resourcesTemplatesList:
        final templates =
            runtime
                .getFilteredConsumerResourceTemplateList(consumerId)
                .map((t) => t.toJson())
                .toList();
        return _resFrame(id, {HubWire.resourceTemplates: templates});
      case HubWire.promptsList:
        final prompts =
            runtime
                .getFilteredConsumerPromptList(consumerId)
                .map((p) => p.toJson())
                .toList();
        return _resFrame(id, {HubWire.prompts: prompts});
      case HubWire.resourcesRead:
      case HubWire.resourcesSubscribe:
      case HubWire.resourcesUnsubscribe:
      case HubWire.promptsGet:
        final r = await runtime.handleConsumerRequest(
          consumerId,
          method!,
          params,
        );
        return _resFrame(id, {
          HubWire.content: r.content ?? const <Map<String, dynamic>>[],
          HubWire.isError: r.isError,
        });
      default:
        return _errFrame(id, 'unknown method: $method');
    }
  } catch (e) {
    return _errFrame(id, e.toString());
  }
}

/// The event frame for a provider [event] (before any transport wrapping).
Map<String, dynamic> hubEventFrame(GatewayEvent event) => {
  HubWire.kind: HubWire.event,
  HubWire.providerId: event.providerId,
  HubWire.eventType: event.eventType,
  HubWire.payload: event.payload,
};

Map<String, dynamic> _resFrame(Object? id, Map<String, dynamic> result) => {
  HubWire.kind: HubWire.res,
  HubWire.id: id,
  HubWire.ok: true,
  HubWire.result: result,
};

Map<String, dynamic> _errFrame(Object? id, String message) => {
  HubWire.kind: HubWire.res,
  HubWire.id: id,
  HubWire.ok: false,
  HubWire.result: {HubWire.error: message},
};

/// Bridges a started [GatewayRuntime] to a frame transport so a **remote**
/// consumer can drive the local provider(s). One instance owns one session (it
/// takes over `runtime.eventBus.onEventRelay` for its [consumerId]).
///
/// Not a relay path: the hub relay never pairs two `role=client` sockets — a
/// client always lands in a node session, and a node is [HubRelayNodeServer],
/// which verifies the caller. This single-session form carries no caller, so
/// it is for in-process wiring and tests ([HubMemoryTransport]) only.
class HubGatewayProvider {
  HubGatewayProvider({
    required this.runtime,
    required this.consumerId,
    required Stream<Map<String, dynamic>> incoming,
    required Future<void> Function(Map<String, dynamic> frame) send,
  }) : _incoming = incoming,
       _send = send;

  /// A started runtime with at least one exposed provider (see
  /// `exposeThroughGateway`) and its poll loop running.
  final GatewayRuntime runtime;

  /// The logical id of the remote consumer this session serves. Used for
  /// policy filtering, event routing, and subscription bookkeeping.
  final String consumerId;

  final Stream<Map<String, dynamic>> _incoming;
  final Future<void> Function(Map<String, dynamic> frame) _send;

  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _started = false;

  bool get isStarted => _started;

  /// Wire event egress and start consuming request frames.
  Future<void> start() async {
    if (_started) return;
    // Event egress: the provider's pushEvent fans through the EventBus to this
    // hook — the package's own supported relay seam (GatewayServerAdapter sets
    // the same field). We ship the event frame over the relay.
    runtime.eventBus.onEventRelay = (cid, event) async {
      if (cid != consumerId) return false;
      await _send(hubEventFrame(event));
      return true;
    };
    _sub = _incoming.listen(_onFrame);
    _started = true;
  }

  Future<void> _onFrame(Map<String, dynamic> frame) async {
    final res = await handleHubRequest(runtime, consumerId, frame);
    if (res != null) await _send(res);
  }

  /// Stop consuming frames and release the event relay hook.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    // Release the relay hook (single-session-per-runtime assumption).
    if (runtime.isStarted) runtime.eventBus.onEventRelay = null;
    _started = false;
  }
}

/// The consumer end of the hub pump: a plain frame client that surfaces a
/// remote node's tools over a hub relay. Needs no [GatewayRuntime] — it only
/// speaks the wire protocol, so a pure marketplace consumer can use it without
/// hosting a gateway.
class HubGatewayConsumer {
  HubGatewayConsumer({
    required Stream<Map<String, dynamic>> incoming,
    required Future<void> Function(Map<String, dynamic> frame) send,
    this.target,
  }) : _incoming = incoming,
       _send = send;

  final Stream<Map<String, dynamic>> _incoming;
  final Future<void> Function(Map<String, dynamic> frame) _send;

  /// One provider this consumer speaks to, or null for the whole node.
  ///
  /// Set, every request carries the gateway target hint
  /// (`_meta.gateway.target`, mcp_gateway 1.0 §3.4) and tool / prompt lists come
  /// back under their own names — the app on the far side calls `led.set`,
  /// not `<providerId>.led.set`. An account peer session is one app, so it is
  /// one provider (platform spec 22 §5.1).
  final String? target;

  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _closed = false;

  /// Begin consuming incoming frames. Call once before issuing requests.
  void start() {
    _sub = _incoming.listen(_onFrame);
  }

  void _onFrame(Map<String, dynamic> frame) {
    switch (frame[HubWire.kind]) {
      case HubWire.res:
        final id = frame[HubWire.id];
        if (id is int) {
          final c = _pending.remove(id);
          if (c != null && !c.isCompleted) {
            c.complete(
              (frame[HubWire.result] as Map?)?.cast<String, dynamic>() ??
                  const <String, dynamic>{},
            );
          }
        }
      case HubWire.event:
        _events.add(frame);
    }
  }

  Future<Map<String, dynamic>> _req(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_closed) throw StateError('HubGatewayConsumer is closed');
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    await _send({
      HubWire.kind: HubWire.req,
      HubWire.id: id,
      HubWire.method: method,
      HubWire.params: _targeted(params),
    });
    return c.future;
  }

  Map<String, dynamic> _targeted(Map<String, dynamic> params) {
    final t = target;
    if (t == null) return params;
    final meta = (params['_meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final gateway =
        (meta['gateway'] as Map?)?.cast<String, dynamic>() ?? const {};
    return {
      ...params,
      '_meta': {
        ...meta,
        'gateway': {...gateway, 'target': t},
      },
    };
  }

  /// Items named `{providerId}.{name}`: with a [target], only that provider's,
  /// under their own names.
  List<Map<String, dynamic>> _named(List? items) {
    final all =
        (items ?? const [])
            .map((x) => (x as Map).cast<String, dynamic>())
            .toList();
    final t = target;
    if (t == null) return all;
    final prefix = '$t.';
    return [
      for (final item in all)
        if ((item[HubWire.name] as String? ?? '').startsWith(prefix))
          {
            ...item,
            HubWire.name: (item[HubWire.name] as String).substring(
              prefix.length,
            ),
          },
    ];
  }

  /// Items carrying gateway provenance: with a [target], only that provider's.
  /// Items without provenance are kept — URIs are never rewritten, so there is
  /// nothing else to tell them apart by.
  List<Map<String, dynamic>> _owned(List? items) {
    final all =
        (items ?? const [])
            .map((x) => (x as Map).cast<String, dynamic>())
            .toList();
    final t = target;
    if (t == null) return all;
    return [
      for (final item in all)
        if (_providerOf(item) == null || _providerOf(item) == t) item,
    ];
  }

  static String? _providerOf(Map<String, dynamic> item) {
    final meta = (item['_meta'] as Map?)?['gateway'] ?? item['_gateway'];
    return meta is Map ? meta['providerId'] as String? : null;
  }

  /// List the remote node's tools — namespaced `{providerId}.{tool}` names, or
  /// the [target] provider's own names.
  Future<List<Map<String, dynamic>>> listTools() async {
    final r = await _req(HubWire.toolsList, const {});
    return _named(r[HubWire.tools] as List?);
  }

  /// Call a remote tool by its (namespaced) [name] with [arguments].
  Future<HubCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final r = await _req(HubWire.toolsCall, {
      HubWire.name: name,
      HubWire.arguments: arguments,
    });
    final content =
        ((r[HubWire.content] as List?) ?? const [])
            .map((c) => (c as Map).cast<String, dynamic>())
            .toList();
    return (content: content, isError: (r[HubWire.isError] as bool?) ?? false);
  }

  /// List the remote node's resources (original URIs — never rewritten).
  Future<List<Map<String, dynamic>>> listResources() async {
    final r = await _req(HubWire.resourcesList, const {});
    return _owned(r[HubWire.resources] as List?);
  }

  /// List the remote node's resource templates.
  Future<List<Map<String, dynamic>>> listResourceTemplates() async {
    final r = await _req(HubWire.resourcesTemplatesList, const {});
    return _owned(r[HubWire.resourceTemplates] as List?);
  }

  /// Read a remote resource by [uri] (routed to the owning provider).
  Future<HubCallResult> readResource(String uri) async {
    final r = await _req(HubWire.resourcesRead, {HubWire.uri: uri});
    final content =
        ((r[HubWire.content] as List?) ?? const [])
            .map((c) => (c as Map).cast<String, dynamic>())
            .toList();
    return (content: content, isError: (r[HubWire.isError] as bool?) ?? false);
  }

  /// MCP resources/subscribe for [uri] (provider-acked on the node side).
  Future<HubCallResult> subscribeResource(String uri) async {
    final r = await _req(HubWire.resourcesSubscribe, {HubWire.uri: uri});
    final content =
        ((r[HubWire.content] as List?) ?? const [])
            .map((c) => (c as Map).cast<String, dynamic>())
            .toList();
    return (content: content, isError: (r[HubWire.isError] as bool?) ?? false);
  }

  /// MCP resources/unsubscribe for [uri].
  Future<void> unsubscribeResource(String uri) =>
      _req(HubWire.resourcesUnsubscribe, {HubWire.uri: uri});

  /// List the remote node's prompts (namespaced names).
  Future<List<Map<String, dynamic>>> listPrompts() async {
    final r = await _req(HubWire.promptsList, const {});
    return _named(r[HubWire.prompts] as List?);
  }

  /// prompts/get by (namespaced) [name] with [arguments].
  Future<HubCallResult> getPrompt(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final r = await _req(HubWire.promptsGet, {
      HubWire.name: name,
      HubWire.arguments: arguments,
    });
    final content =
        ((r[HubWire.content] as List?) ?? const [])
            .map((c) => (c as Map).cast<String, dynamic>())
            .toList();
    return (content: content, isError: (r[HubWire.isError] as bool?) ?? false);
  }

  /// Subscribe to a provider's events (empty [eventTypes] = all).
  Future<void> subscribe(
    String providerId, {
    List<String> eventTypes = const [],
  }) => _req(HubWire.subscribe, {
    HubWire.providerId: providerId,
    HubWire.eventTypes: eventTypes,
  });

  /// Stop receiving a provider's events.
  Future<void> unsubscribe(String providerId) =>
      _req(HubWire.unsubscribe, {HubWire.providerId: providerId});

  /// Incoming event frames (`providerId` / `eventType` / `payload`).
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Tear down: cancel the subscription, fail pending requests, close events.
  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('closed'));
    }
    _pending.clear();
    await _events.close();
  }
}

/// A linked in-memory frame transport pair — endpoint A's send reaches B's
/// incoming and vice versa. For tests and local wiring; production hosts inject
/// a firestore or ws relay transport (spec 15 §4).
class HubMemoryTransport {
  final StreamController<Map<String, dynamic>> _toB =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _toA =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Endpoint A incoming (frames B sent).
  Stream<Map<String, dynamic>> get incomingA => _toA.stream;

  /// Endpoint A send (delivered to B).
  Future<void> sendA(Map<String, dynamic> frame) async => _toB.add(frame);

  /// Endpoint B incoming (frames A sent).
  Stream<Map<String, dynamic>> get incomingB => _toB.stream;

  /// Endpoint B send (delivered to A).
  Future<void> sendB(Map<String, dynamic> frame) async => _toA.add(frame);

  Future<void> close() async {
    await _toA.close();
    await _toB.close();
  }
}
