import 'dart:async';

import 'package:mcp_client/mcp_client.dart';
import 'package:mcp_gateway/mcp_gateway.dart';

/// Adds a listener for one notification [method] on a client that other code
/// may also be listening on, and returns the function that removes it.
///
/// Injected, not done here: `Client.onNotification` keeps one handler per
/// method, so registering directly would take the slot from whatever else on
/// the lending device already watches that connection — its own open app.
/// Hosts pass their shared fan-out (brain_kernel `SharedClientNotifications`).
typedef NotificationTap =
    void Function() Function(
      String method,
      Future<void> Function(Map<String, dynamic> params) handler,
    );

/// Subscribe or release one resource on a shared client. Injected for the same
/// reason as [NotificationTap]: the device knows only "subscribed" or not, so
/// the release must be reference-counted across everyone using the connection
/// (brain_kernel `SharedResourceSubscriptions`).
typedef ResourceSubscriptionTap = Future<void> Function(String uri);

/// A connection the lending device holds, offered as one gateway provider
/// (platform spec 22 §5.2).
///
/// The provider's schema is what the connection lists; every dispatch goes to
/// that connection's [Client]; list changes and resource updates on the
/// connection become gateway schema updates and resource notifications. The
/// gateway does the rest — id pairing, fan-out to the sessions that asked,
/// deadlines, queue bounds.
class ExposedConnection {
  ExposedConnection._({
    required this.providerId,
    required this.client,
    required GatewayClientAdapter adapter,
    required ResourceSubscriptionTap subscribe,
    required ResourceSubscriptionTap unsubscribe,
  }) : _adapter = adapter,
       _subscribe = subscribe,
       _unsubscribe = unsubscribe;

  final String providerId;
  final Client client;
  final GatewayClientAdapter _adapter;
  final ResourceSubscriptionTap _subscribe;
  final ResourceSubscriptionTap _unsubscribe;
  final List<void Function()> _taps = [];
  final Map<String, int> _subscriptions = {};
  int _schemaVersion = 1;
  bool _closed = false;

  /// Resources the borrowing sessions hold subscriptions on, with counts.
  Map<String, int> get subscriptions => Map.unmodifiable(_subscriptions);

  /// Register [client] as provider [providerId] on [runtime] and start serving.
  static Future<ExposedConnection> expose({
    required GatewayRuntime runtime,
    required String providerId,
    required Client client,
    required NotificationTap listen,
    required ResourceSubscriptionTap subscribe,
    required ResourceSubscriptionTap unsubscribe,
    String? version,
  }) async {
    final adapter = GatewayClientAdapter(runtime);
    final exposed = ExposedConnection._(
      providerId: providerId,
      client: client,
      adapter: adapter,
      subscribe: subscribe,
      unsubscribe: unsubscribe,
    );
    adapter.onDispatch = exposed._dispatch;
    await adapter.register(
      ProviderRegistration(
        providerId: providerId,
        version: version,
        schemaVersion: exposed._schemaVersion,
        schema: await exposed._schema(),
        capabilities: const ProviderCapabilities(
          tools: true,
          resources: true,
          prompts: true,
          resourceSubscription: true,
          eventPush: true,
        ),
      ),
    );
    unawaited(adapter.startPollLoop());

    Future<void> refresh(Map<String, dynamic> _) => exposed.refresh();
    exposed._taps
      ..add(listen('notifications/tools/list_changed', refresh))
      ..add(listen('notifications/resources/list_changed', refresh))
      ..add(listen('notifications/prompts/list_changed', refresh))
      ..add(
        listen('notifications/resources/updated', (params) async {
          final uri = params['uri'];
          if (uri is String && !exposed._closed) {
            await adapter.notifyResourceUpdated(uri);
          }
        }),
      );
    return exposed;
  }

  /// Re-read the connection's lists and publish them as the provider schema.
  Future<void> refresh() async {
    if (_closed) return;
    _schemaVersion++;
    await _adapter.updateSchema(_schemaVersion, await _schema());
  }

  /// Everything the connection lists. A list the server does not support
  /// reads as empty — a tools-only board is a valid provider.
  Future<ProviderSchemaBody> _schema() async {
    Future<List<T>> orEmpty<T>(Future<List<T>> Function() read) async {
      try {
        return await read();
      } catch (_) {
        return <T>[];
      }
    }

    final tools = await orEmpty(client.listTools);
    final resources = await orEmpty(client.listResources);
    final templates = await orEmpty(client.listResourceTemplates);
    final prompts = await orEmpty(client.listPrompts);
    return ProviderSchemaBody(
      tools: [for (final t in tools) ToolDefinition.fromJson(t.toJson())],
      resources: [
        for (final r in resources) ResourceDefinition.fromJson(r.toJson()),
      ],
      resourceTemplates: [
        for (final t in templates)
          ResourceTemplateDefinition.fromJson(t.toJson()),
      ],
      prompts: [for (final p in prompts) PromptDefinition.fromJson(p.toJson())],
    );
  }

  Future<DispatchResult> _dispatch(DispatchPayload d) async {
    final params = d.params;
    try {
      switch (d.method) {
        case 'tools/call':
          final r = await client.callTool(
            params['name'] as String,
            (params['arguments'] as Map?)?.cast<String, dynamic>() ?? const {},
          );
          return DispatchResult(
            content: [for (final c in r.content) c.toJson()],
            isError: r.isError ?? false,
          );
        case 'resources/read':
          final r = await client.readResource(params['uri'] as String);
          return DispatchResult(
            content: [for (final c in r.contents) c.toJson()],
          );
        case 'resources/subscribe':
          final uri = params['uri'] as String;
          final count = _subscriptions[uri] ?? 0;
          if (count == 0) await _subscribe(uri);
          _subscriptions[uri] = count + 1;
          return const DispatchResult(content: []);
        case 'resources/unsubscribe':
          final uri = params['uri'] as String;
          final count = _subscriptions[uri] ?? 0;
          if (count <= 1) {
            if (_subscriptions.remove(uri) != null) await _unsubscribe(uri);
          } else {
            _subscriptions[uri] = count - 1;
          }
          return const DispatchResult(content: []);
        case 'prompts/get':
          final r = await client.getPrompt(
            params['name'] as String,
            (params['arguments'] as Map?)?.cast<String, dynamic>(),
          );
          return DispatchResult(
            content: [for (final m in r.messages) m.toJson()],
          );
        default:
          return DispatchResult(
            content: [
              {'type': 'text', 'text': 'method not found: ${d.method}'},
            ],
            isError: true,
          );
      }
    } catch (e) {
      return DispatchResult(
        content: [
          {'type': 'text', 'text': e.toString()},
        ],
        isError: true,
      );
    }
  }

  /// Stop offering the connection: listeners removed, the subscriptions the
  /// borrowing sessions held released, the provider unregistered. The
  /// connection itself stays with whoever opened it.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final remove in _taps) {
      remove();
    }
    _taps.clear();
    for (final uri in _subscriptions.keys.toList()) {
      try {
        await _unsubscribe(uri);
      } catch (_) {
        // Releasing is best-effort; the provider is going away regardless.
      }
    }
    _subscriptions.clear();
    // Unregistering ends the poll loop; waiting for the loop itself would hold
    // the caller until the in-flight long poll times out.
    await _adapter.unregister();
  }
}
