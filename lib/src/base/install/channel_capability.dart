/// Host `channel.*` capability — bidirectional multi-connector messaging.
///
/// Exposes `mcp_channel` (the real conversational framework: connectors +
/// `events`/`send` + sessions) as `channel.*` tools. The host owns the
/// long-lived state (a connector registry + a shared `SessionManager`); tools
/// operate against it by `channelId`. See
/// `docs/03_DDD/channel-capability.md` for the full design + phasing.
///
/// P1 (this file): connector registry · `list`/`status`/`send` ·
/// `session.history`, plus a built-in **in-app** connector backed by the
/// canonical `KvStoragePortAdapter` (the workspace notification feed, now one
/// channel among many — not an ops engine). P2 (agentic inbound via
/// `ChannelHandler` + kernel `MessageProcessor`/`ToolProvider`) and P3
/// (member↔channel binding + external connectors) follow.
library;

import 'dart:async' show unawaited;
import 'dart:convert' show jsonEncode;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_channel/mcp_channel.dart';

/// Capability namespace — exposed names are `channel.<verb>`.
const String channelCapabilityId = 'channel';

/// In-app conversation feed as a [ChannelPort] connector. `send` persists the
/// message to the canonical KV (`ws/<wsId>/messages/<id>`) and emits it on the
/// event stream; the host owns one of these so the workspace feed is "just
/// another channel" behind `channel.*`. No external credentials.
class _InAppConnector extends BaseConnector {
  _InAppConnector(this._kv, this._facts);

  /// Resolves the active project's canonical KV. Null when no project is open
  /// (the feed is disabled then).
  final KvStoragePortAdapter? Function() _kv;

  /// Resolves the active project's flowbrain FactFacade so feed messages are
  /// extracted into the knowledge graph (the in-app feed's fact wiring, lifted
  /// out of the old ops ChannelAdapter). Null when no project is open.
  final FactFacade? Function() _facts;

  @override
  ConnectorConfig get config => const _InAppConfig();

  @override
  ChannelPolicy get policy => const ChannelPolicy();

  @override
  ChannelIdentity get identity => const ChannelIdentity(
    platform: 'in_app',
    channelId: 'in_app',
    displayName: 'In-app feed',
  );

  @override
  ChannelCapabilities get capabilities => extendedCapabilities.toBase();

  @override
  ExtendedChannelCapabilities get extendedCapabilities =>
      const ExtendedChannelCapabilities();

  @override
  Future<void> start() async {
    updateConnectionState(ConnectionState.connected);
  }

  @override
  Future<void> doStop() async {
    updateConnectionState(ConnectionState.disconnected);
  }

  @override
  Future<void> send(ChannelResponse response) async {
    await sendWithResult(response);
  }

  @override
  Future<SendResult> sendWithResult(ChannelResponse response) async {
    // Outbound (agent/system → feed). Persist only — do NOT emit an inbound
    // event, or an attached ChannelHandler would re-process the agent's own
    // reply and loop. Inbound arrives via [receiveInbound].
    final id = await _persist(
      role: 'assistant',
      conversation: response.conversation,
      text: response.text ?? '',
      replyTo: response.replyTo,
    );
    if (id == null) {
      return const SendResult(
        success: false,
        error: ChannelError(
          code: 'channel.no_project',
          message: 'no active project',
        ),
      );
    }
    final facts = _facts();
    if (facts != null && (response.text ?? '').isNotEmpty) {
      unawaited(
        facts
            .extractFragments(response.text!, 'text/plain')
            .catchError((_) => <EvidenceFragment>[]),
      );
    }
    return SendResult(success: true, messageId: id);
  }

  /// Inject an inbound user message (the agentic trigger): persist it and emit
  /// a `ChannelEvent` so the attached [ChannelHandler] routes it to the agent.
  /// Returns the persisted message id, or null when no project is active.
  Future<String?> receiveInbound({
    required String conversationId,
    String? userId,
    required String text,
  }) async {
    final conversation = ConversationKey(
      channel: identity,
      conversationId: conversationId,
      userId: userId,
    );
    final id = await _persist(
      role: 'user',
      conversation: conversation,
      text: text,
      replyTo: null,
    );
    if (id == null) return null;
    emitEvent(
      ChannelEvent.message(id: id, conversation: conversation, text: text),
    );
    return id;
  }

  /// Monotonic message counter — keeps feed ids unique so two messages with
  /// identical text in one conversation don't collide (a chat feed must not
  /// dedupe by content). `channel_notify` keeps idempotency by passing its
  /// notificationId as [replyTo], which is used as the id when present.
  int _seq = 0;

  /// Persist one message to the workspace feed KV. Returns the id, or null
  /// when no project is active (feed disabled).
  Future<String?> _persist({
    required String role,
    required ConversationKey conversation,
    required String text,
    required String? replyTo,
  }) async {
    final store = _kv();
    final wsId = store?.workspaceId;
    if (store == null || wsId == null || wsId.isEmpty) return null;
    final id = replyTo ?? '${conversation.conversationId}-${_seq++}';
    await store.set('ws/$wsId/messages/$id', <String, dynamic>{
      'role': role,
      'conversationId': conversation.conversationId,
      'userId': conversation.userId,
      'text': text,
      'replyTo': replyTo,
      '_createdAt': DateTime.now().toIso8601String(),
    });
    return id;
  }

  @override
  Future<void> sendTyping(ConversationKey conversation) async {
    // In-app feed has no typing indicator.
  }
}

class _InAppConfig implements ConnectorConfig {
  const _InAppConfig();
  @override
  String get channelType => 'in_app';
  @override
  bool get autoReconnect => false;
  @override
  Duration get reconnectDelay => Duration.zero;
  @override
  int get maxReconnectAttempts => 0;
}

/// Register `channel.*` over a host-owned connector registry. [kv] resolves the
/// active project's canonical KV (for the in-app feed). [askAgent] (optional)
/// turns the in-app feed into an **agentic** channel: an inbound message
/// (`channel.receive`) is routed to the agent named by its `conversationId`
/// and the reply is sent back to the feed (P2). External connectors are added
/// once credentials are provisioned from host settings (P3).
List<String> registerChannelCapability({
  required HostToolRegistry registry,
  required KvStoragePortAdapter? Function() kv,
  required FactFacade? Function() facts,
  Future<String> Function(String agentId, String message)? askAgent,
}) {
  // Host-owned long-lived state.
  final connectors = <String, ExtendedChannelPort>{};
  final sessions = SessionManager(InMemorySessionStore());

  // The in-app feed is always available as `in_app`.
  final inApp = _InAppConnector(kv, facts);
  connectors['in_app'] = inApp;
  inApp.start();

  // Agentic inbound (P2): attach a ChannelHandler whose MessageProcessor
  // delegates to the host agent. The conversationId names the target agent
  // (the same id `channel_notify` addresses as recipient). Loop-safe — the
  // connector only emits on `receiveInbound`, never on the agent's reply.
  if (askAgent != null) {
    final handler = ChannelHandler(
      port: inApp,
      sessionManager: sessions,
      processor: _AgentMessageProcessor(askAgent),
    );
    unawaited(handler.start());
  }

  ExtendedChannelPort? conn(String id) => connectors[id];

  final exposed = <String>[];

  exposed.add(
    registry.registerExposed(
      bundleId: channelCapabilityId,
      rawName: 'list',
      description: 'List connected channels (id · platform · running state).',
      inputSchema: const <String, dynamic>{'type': 'object'},
      handler:
          (args) async => _result(<String, dynamic>{
            'ok': true,
            'channels': <Map<String, dynamic>>[
              for (final e in connectors.entries)
                <String, dynamic>{
                  'channelId': e.key,
                  'platform': e.value.identity.platform,
                  'running': e.value.isRunning,
                },
            ],
          }, isError: false),
    ),
  );

  exposed.add(
    registry.registerExposed(
      bundleId: channelCapabilityId,
      rawName: 'status',
      description: 'Connection state + platform of a channel.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'channelId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['channelId'],
      },
      handler: (args) async {
        final c = conn(args['channelId'] as String? ?? '');
        if (c == null) {
          return _result(<String, dynamic>{
            'ok': false,
            'code': 'channel.not_found',
            'error': 'unknown channelId',
          }, isError: true);
        }
        return _result(<String, dynamic>{
          'ok': true,
          'channelId': args['channelId'],
          'platform': c.identity.platform,
          'running': c.isRunning,
        }, isError: false);
      },
    ),
  );

  exposed.add(
    registry.registerExposed(
      bundleId: channelCapabilityId,
      // §6 destructive — sending a message to an external platform is an
      // irreversible outward action; gated through the host confirm callback.
      destructive: true,
      rawName: 'send',
      description:
          'Send a text message to a conversation on a channel (the in-app feed '
          'or a connected external platform).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'channelId': <String, dynamic>{
            'type': 'string',
            'description': 'Target channel (default "in_app").',
          },
          'conversationId': <String, dynamic>{'type': 'string'},
          'userId': <String, dynamic>{'type': 'string'},
          'text': <String, dynamic>{'type': 'string'},
          'replyTo': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['conversationId', 'text'],
      },
      handler: (args) async {
        final c = conn((args['channelId'] as String?) ?? 'in_app');
        if (c == null) {
          return _result(<String, dynamic>{
            'ok': false,
            'code': 'channel.not_found',
            'error': 'unknown channelId',
          }, isError: true);
        }
        final response = ChannelResponse.text(
          conversation: ConversationKey(
            channel: c.identity,
            conversationId: args['conversationId'] as String,
            userId: args['userId'] as String?,
          ),
          text: args['text'] as String,
          replyTo: args['replyTo'] as String?,
        );
        final result = await c.sendWithResult(response);
        return _result(<String, dynamic>{
          'ok': result.success,
          'success': result.success,
          if (result.messageId != null) 'messageId': result.messageId,
          if (result.error != null) 'error': result.error!.message,
        }, isError: !result.success);
      },
    ),
  );

  exposed.add(
    registry.registerExposed(
      bundleId: channelCapabilityId,
      rawName: 'session.history',
      description: 'Conversation history (in-app feed messages, newest first).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'conversationId': <String, dynamic>{'type': 'string'},
          'limit': <String, dynamic>{'type': 'integer'},
        },
      },
      handler: (args) async {
        final store = kv();
        final wsId = store?.workspaceId;
        if (store == null || wsId == null || wsId.isEmpty) {
          return _result(<String, dynamic>{
            'ok': false,
            'code': 'channel.no_project',
            'error': 'no active project',
          }, isError: true);
        }
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        final convo = args['conversationId'] as String?;
        final keys = await store.keys(prefix: 'ws/$wsId/messages');
        final msgs = <Map<String, dynamic>>[];
        for (final k in keys.take(limit * 3)) {
          final raw = await store.get(k);
          if (raw is! Map) continue;
          final m = raw.cast<String, dynamic>();
          if (convo != null && m['conversationId'] != convo) continue;
          msgs.add(m);
          if (msgs.length >= limit) break;
        }
        return _result(<String, dynamic>{
          'ok': true,
          'messages': msgs,
        }, isError: false);
      },
    ),
  );

  exposed.add(
    registry.registerExposed(
      bundleId: channelCapabilityId,
      rawName: 'receive',
      description:
          'Inject an inbound user message into the in-app feed. When an agent '
          'is wired, the message is routed to the agent named by conversationId '
          'and the reply is posted back to the feed (read it via '
          '`channel.session.history`).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'conversationId': <String, dynamic>{
            'type': 'string',
            'description': 'Target conversation = the agent id to ask.',
          },
          'userId': <String, dynamic>{'type': 'string'},
          'text': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['conversationId', 'text'],
      },
      handler: (args) async {
        final id = await inApp.receiveInbound(
          conversationId: args['conversationId'] as String,
          userId: args['userId'] as String?,
          text: args['text'] as String,
        );
        if (id == null) {
          return _result(<String, dynamic>{
            'ok': false,
            'code': 'channel.no_project',
            'error': 'no active project',
          }, isError: true);
        }
        return _result(<String, dynamic>{
          'ok': true,
          'messageId': id,
          'agentic': askAgent != null,
        }, isError: false);
      },
    ),
  );

  return exposed;
}

/// [MessageProcessor] that answers an inbound message with the host agent.
/// The event's `conversationId` names the target agent (the same id
/// `channel_notify` addresses as recipient). A failed ask is surfaced as a
/// plain reply so the loop always completes.
class _AgentMessageProcessor implements MessageProcessor {
  _AgentMessageProcessor(this._askAgent);

  final Future<String> Function(String agentId, String message) _askAgent;

  @override
  Future<ProcessResult> process(ChannelEvent event, Session session) async {
    final text = event.text ?? '';
    if (text.isEmpty) return ProcessResult.ignore();
    String reply;
    try {
      reply = await _askAgent(event.conversation.conversationId, text);
    } catch (e) {
      reply = 'agent error: $e';
    }
    return ProcessResult.respond(
      ChannelResponse.text(conversation: event.conversation, text: reply),
    );
  }
}

KernelToolResult _result(Object? value, {required bool isError}) {
  return KernelToolResult(
    content: <KernelContent>[KernelTextContent(text: jsonEncode(value))],
    isError: isError,
  );
}
