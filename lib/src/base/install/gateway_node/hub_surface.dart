import 'dart:async';

import 'package:mcp_client/mcp_client.dart';

import 'hub_pump.dart';

/// Surfacing adapter — presents a [HubGatewayConsumer] as a standard
/// `mcp_client` [ClientTransport] so a host opens the remote hub node through
/// its ordinary MCP server-open path (e.g. `KernelClientHost.connectWith(id,
/// transport)`), with **no host-specific glue and no core change**.
///
/// The host runtime speaks MCP JSON-RPC over the transport; this shim answers
/// the handshake + the full-MCP verbs (mcp_gateway 0.1.1) by translating to the
/// hub consumer's gateway dispatch calls:
/// - `initialize` → tools + resources(subscribe) + prompts capabilities.
/// - `tools/list|call` · `resources/list|templates/list|read|subscribe|unsubscribe`
///   · `prompts/list|get` → the matching [HubGatewayConsumer] verb. URIs are
///   NEVER rewritten (package contract) — a renderer reads ui:// URIs as-is,
///   which is what makes hub-served UI work end-to-end.
/// - node events whose eventType is a standard MCP notification name are
///   forwarded as JSON-RPC notifications (e.g. `notifications/resources/updated`).
/// Client notifications (no id) are dropped; any other request gets an empty
/// result so the client never hangs.
class HubConsumerTransport implements ClientTransport {
  HubConsumerTransport(
    this._consumer, {
    String serverName = 'hub-node',
    String serverVersion = '1.0.0',
    String protocolVersion = '2025-03-26',
  }) : _name = serverName,
       _version = serverVersion,
       _protocol = protocolVersion;

  final HubGatewayConsumer _consumer;
  final String _name;
  final String _version;
  final String _protocol;

  final StreamController<dynamic> _out = StreamController<dynamic>.broadcast();
  final Completer<void> _closed = Completer<void>();
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  /// Forward node events that carry standard MCP notification names
  /// (`notifications/*`) to the client as JSON-RPC notifications. Call once
  /// after construction when event forwarding is wanted.
  void forwardEvents() {
    _eventSub ??= _consumer.events.listen((e) {
      final type = e[HubWire.eventType] as String?;
      if (type == null || !type.startsWith('notifications/')) return;
      if (_out.isClosed) return;
      _out.add({
        'jsonrpc': '2.0',
        'method': type,
        'params':
            (e[HubWire.payload] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      });
    });
  }

  @override
  Stream<dynamic> get onMessage => _out.stream;

  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(dynamic message) {
    final map = (message as Map).cast<String, dynamic>();
    final method = map['method'] as String?;
    final id = map['id'];
    if (method == null) return;

    switch (method) {
      case 'initialize':
        _reply(id, {
          'protocolVersion': _protocol,
          'serverInfo': {'name': _name, 'version': _version},
          'capabilities': {
            'tools': {},
            'resources': {'subscribe': true},
            'prompts': {},
          },
        });
      case 'tools/list':
        _consumer
            .listTools()
            .then((tools) => _reply(id, {'tools': tools}))
            .catchError((Object e) => _replyError(id, e));
      case 'tools/call':
        final params =
            (map['params'] as Map?)?.cast<String, dynamic>() ?? const {};
        final name = params['name'] as String? ?? '';
        final args =
            (params['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};
        _consumer
            .callTool(name, args)
            .then(
              (r) => _reply(id, {'content': r.content, 'isError': r.isError}),
            )
            .catchError((Object e) => _replyError(id, e));
      case 'resources/list':
        _consumer
            .listResources()
            .then((r) => _reply(id, {'resources': r}))
            .catchError((Object e) => _replyError(id, e));
      case 'resources/templates/list':
        _consumer
            .listResourceTemplates()
            .then((r) => _reply(id, {'resourceTemplates': r}))
            .catchError((Object e) => _replyError(id, e));
      case 'resources/read':
        final uri = ((map['params'] as Map?)?['uri'] as String?) ?? '';
        _consumer
            .readResource(uri)
            .then(
              (r) =>
                  r.isError
                      ? _replyError(id, r.content.toString())
                      : _reply(id, {'contents': r.content}),
            )
            .catchError((Object e) => _replyError(id, e));
      case 'resources/subscribe':
        final uri = ((map['params'] as Map?)?['uri'] as String?) ?? '';
        _consumer
            .subscribeResource(uri)
            .then(
              (r) =>
                  r.isError
                      ? _replyError(id, r.content.toString())
                      : _reply(id, const {}),
            )
            .catchError((Object e) => _replyError(id, e));
      case 'resources/unsubscribe':
        final uri = ((map['params'] as Map?)?['uri'] as String?) ?? '';
        _consumer
            .unsubscribeResource(uri)
            .then((_) => _reply(id, const {}))
            .catchError((Object e) => _replyError(id, e));
      case 'prompts/list':
        _consumer
            .listPrompts()
            .then((r) => _reply(id, {'prompts': r}))
            .catchError((Object e) => _replyError(id, e));
      case 'prompts/get':
        final params =
            (map['params'] as Map?)?.cast<String, dynamic>() ?? const {};
        _consumer
            .getPrompt(
              params['name'] as String? ?? '',
              (params['arguments'] as Map?)?.cast<String, dynamic>() ??
                  const {},
            )
            .then(
              (r) =>
                  r.isError
                      ? _replyError(id, r.content.toString())
                      : _reply(id, {'messages': r.content}),
            )
            .catchError((Object e) => _replyError(id, e));
      default:
        // Notifications (no id) need no response; unknown requests get an empty
        // result rather than a hang.
        if (id != null) _reply(id, const {});
    }
  }

  void _reply(Object? id, Map<String, dynamic> result) {
    if (id == null || _out.isClosed) return;
    _out.add({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  void _replyError(Object? id, Object e) {
    if (id == null || _out.isClosed) return;
    _out.add({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32000, 'message': e.toString()},
    });
  }

  @override
  void close() {
    _eventSub?.cancel();
    if (!_closed.isCompleted) _closed.complete();
    _out.close();
  }
}
