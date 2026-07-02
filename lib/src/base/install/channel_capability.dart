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
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:appplayer_secure/appplayer_secure.dart' show SecureStorage;
import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_channel/mcp_channel.dart';

// Vendored channel_drivers recipe (brain_kernel/recipes) — external connector
// assembly (`channel.connect`/`channel.disconnect`). Committed copy, never
// hand-edited (see debug/tool/sync_channel_drivers_fork.sh).
import 'channel_drivers/channel_drivers.dart';

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
  SecureStorage? secure,
}) {
  // Host-owned long-lived state.
  final connectors = <String, ExtendedChannelPort>{};
  final sessions = SessionManager(InMemorySessionStore());

  // Inbound routing bindings: conversationId → target agentId. Data-driven so
  // an EXTERNAL conversation (a kakao room, a slack channel) routes to the
  // right agent — the in-app feed uses conversationId == agentId, but external
  // platforms carry native conversation ids. Persisted to the project KV so
  // bindings survive a reboot; the host code stays generic, the routing policy
  // is data (`channel.bind` / `channel.unbind`).
  const bindingsKey = 'channel/inbound_bindings';
  final bindings = <String, String>{};
  unawaited(() async {
    try {
      final raw = await kv()?.get(bindingsKey);
      if (raw is Map) {
        raw.forEach((c, a) => bindings[c.toString()] = a.toString());
      }
    } catch (_) {
      /* best-effort hydrate */
    }
  }());
  Future<void> persistBindings() async {
    try {
      await kv()?.set(bindingsKey, bindings);
    } catch (_) {
      /* best-effort */
    }
  }

  // Attach an agentic ChannelHandler to a connector so its inbound messages
  // route to an agent (conversationId → binding → agentId) and the reply is
  // sent back. Loop-safe — connectors only emit on real inbound, never on the
  // agent's own reply. No-op when no `askAgent` is wired.
  void attachAgentHandler(ExtendedChannelPort port) {
    if (askAgent == null) return;
    final handler = ChannelHandler(
      port: port,
      sessionManager: sessions,
      processor: _AgentMessageProcessor(askAgent, bindings),
    );
    unawaited(handler.start());
  }

  // The in-app feed is always available as `in_app`.
  final inApp = _InAppConnector(kv, facts);
  connectors['in_app'] = inApp;
  inApp.start();
  attachAgentHandler(inApp);

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

  // P3 — external connectors. The channel_drivers recipe provisions real
  // `mcp_channel` connectors (slack / telegram / email / kakao / …) into the
  // SAME `connectors` map at runtime via `channel.connect` / `channel.disconnect`
  // — so `channel.send` / `channel.receive` reach them, identically across
  // Studio / AppPlayer / FlowBrain (vendored recipe, no core change).
  // Platform-gated to desktop for this host.
  final driverRegistry = ChannelDriverRegistry();
  registerChannelConnectors(driverRegistry);
  final driverTools = channelDriverTools(
    registry: driverRegistry,
    connectors: connectors,
    platform: ChannelPlatform.desktop,
  );
  for (final entry in driverTools.entries) {
    final rawName = entry.key.startsWith('channel.')
        ? entry.key.substring('channel.'.length)
        : entry.key;
    final handler = entry.value;
    exposed.add(
      registry.registerExposed(
        bundleId: channelCapabilityId,
        rawName: rawName,
        description: rawName == 'connect'
            ? 'Provision + connect an external channel connector '
                '(`platform` + `id` + `params`, e.g. slack / telegram / email / '
                'kakao). Adds it to the live connectors map so `channel.send` / '
                '`channel.receive` reach it. §6 destructive (external I/O).'
            : 'Stop + deregister a connected external channel connector (`id`).',
        inputSchema: rawName == 'connect'
            ? const <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'platform': <String, dynamic>{'type': 'string'},
                  'id': <String, dynamic>{'type': 'string'},
                  'params': <String, dynamic>{'type': 'object'},
                },
                'required': <String>['platform', 'id'],
              }
            : const <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'id': <String, dynamic>{'type': 'string'},
                },
                'required': <String>['id'],
              },
        handler: (args) async {
          var callArgs = args;
          // On connect, when no inline params are given, resolve this
          // connector's stored credentials from the secure vault — so secrets
          // never travel in the tool call / chat / logs. Inline params still
          // win when explicitly provided.
          if (rawName == 'connect' && secure != null) {
            final id = callArgs['id'] as String?;
            final hasParams = (callArgs['params'] as Map?)?.isNotEmpty ?? false;
            if (id != null && !hasParams) {
              final raw = await secure.read('channel.cred/$id');
              if (raw != null && raw.isNotEmpty) {
                try {
                  callArgs = <String, dynamic>{
                    ...callArgs,
                    'params': jsonDecode(raw),
                  };
                } catch (_) {
                  /* stored cred corrupt → fall through to recipe validation */
                }
              }
            }
          }
          final out =
              await handler(callArgs) as Map<String, dynamic>? ?? const {};
          // On a successful connect, give the new connector the same agentic
          // inbound routing the in-app feed has, so external inbound reaches
          // agents (resolved via bindings) too.
          if (rawName == 'connect' && out['ok'] == true) {
            final id = out['id'] as String?;
            final port = id == null ? null : connectors[id];
            if (port != null) attachAgentHandler(port);
          }
          return _result(out, isError: out['ok'] == false);
        },
      ),
    );
  }

  // Inbound routing bindings (data) — map an external conversation to the agent
  // that should handle it. Generic: the host reads the binding, the policy is
  // data. `channel.receive` from a bound conversation routes to that agent
  // (which can then `process_approve` / `agent_route` / `channel.send`).
  exposed.add(
    registry.registerExposed(
      bundleId: channelCapabilityId,
      rawName: 'bind',
      description:
          'Route inbound from a conversation to an agent: bind '
          '`{conversationId, agentId}`. The agent then handles that '
          'conversation (approve via `process_approve`, delegate via '
          '`agent_route`, reply/notify via `channel.send`). Persisted.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'conversationId': <String, dynamic>{'type': 'string'},
          'agentId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['conversationId', 'agentId'],
      },
      handler: (args) async {
        final conv = (args['conversationId'] as String?)?.trim() ?? '';
        final agent = (args['agentId'] as String?)?.trim() ?? '';
        if (conv.isEmpty || agent.isEmpty) {
          return _result(<String, dynamic>{
            'ok': false,
            'error': 'conversationId and agentId required',
          }, isError: true);
        }
        bindings[conv] = agent;
        await persistBindings();
        return _result(<String, dynamic>{
          'ok': true,
          'conversationId': conv,
          'agentId': agent,
        }, isError: false);
      },
    ),
  );

  exposed.add(
    registry.registerExposed(
      bundleId: channelCapabilityId,
      rawName: 'unbind',
      description: 'Remove an inbound routing binding (`conversationId`).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'conversationId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['conversationId'],
      },
      handler: (args) async {
        final conv = (args['conversationId'] as String?)?.trim() ?? '';
        final removed = bindings.remove(conv) != null;
        if (removed) await persistBindings();
        return _result(<String, dynamic>{'ok': true, 'removed': removed},
            isError: false);
      },
    ),
  );

  exposed.add(
    registry.registerExposed(
      bundleId: channelCapabilityId,
      rawName: 'bindings',
      description: 'List inbound routing bindings (conversationId → agentId).',
      inputSchema: const <String, dynamic>{'type': 'object'},
      handler: (args) async => _result(<String, dynamic>{
        'ok': true,
        'bindings': <Map<String, dynamic>>[
          for (final e in bindings.entries)
            <String, dynamic>{'conversationId': e.key, 'agentId': e.value},
        ],
      }, isError: false),
    ),
  );

  // Credential vault (secure). Store a connector's credentials in the OS
  // keychain keyed by connector id, so `channel.connect` resolves them by id
  // and secrets never travel in a tool call / chat / log. No plaintext get — a
  // caller can list ids and set/remove, never read a stored secret back. The
  // `id` distinguishes accounts, so different accounts on the same platform are
  // just different ids (host-owned or app-scoped by id convention). Only wired
  // when a secure store is available.
  if (secure != null) {
    final store = secure;
    const idsKey = 'channel.cred._ids';
    Future<List<String>> readIds() async {
      try {
        final raw = await store.read(idsKey);
        if (raw == null || raw.isEmpty) return <String>[];
        return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      } catch (_) {
        return <String>[];
      }
    }

    exposed.add(
      registry.registerExposed(
        bundleId: channelCapabilityId,
        rawName: 'credential_set',
        description:
            'Securely store a connector\'s credentials (OS keychain), keyed by '
            '`id`. `channel.connect{id}` then resolves them — secrets never '
            'travel in the connect call. `params` = that platform\'s fields '
            '(e.g. slack `botToken`/`signingSecret`, kakao `botId`, email '
            '`botEmail`/`host`/`username`/`password`). No plaintext read-back.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
            'platform': <String, dynamic>{'type': 'string'},
            'params': <String, dynamic>{'type': 'object'},
          },
          'required': <String>['id', 'params'],
        },
        handler: (args) async {
          final id = (args['id'] as String?)?.trim() ?? '';
          final params = (args['params'] as Map?)?.cast<String, dynamic>();
          if (id.isEmpty || params == null || params.isEmpty) {
            return _result(<String, dynamic>{
              'ok': false,
              'error': 'id and non-empty params required',
            }, isError: true);
          }
          await store.write('channel.cred/$id', jsonEncode(params));
          final ids = await readIds();
          if (!ids.contains(id)) {
            ids.add(id);
            await store.write(idsKey, jsonEncode(ids));
          }
          return _result(<String, dynamic>{
            'ok': true,
            'id': id,
            if (args['platform'] != null) 'platform': args['platform'],
            'fields': params.keys.toList(), // names only, never values
          }, isError: false);
        },
      ),
    );

    exposed.add(
      registry.registerExposed(
        bundleId: channelCapabilityId,
        rawName: 'credential_ids',
        description:
            'List connector ids that have stored credentials (ids only — never '
            'the secret values).',
        inputSchema: const <String, dynamic>{'type': 'object'},
        handler: (args) async =>
            _result(<String, dynamic>{'ok': true, 'ids': await readIds()},
                isError: false),
      ),
    );

    exposed.add(
      registry.registerExposed(
        bundleId: channelCapabilityId,
        rawName: 'credential_remove',
        description: 'Delete a connector\'s stored credentials (`id`).',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['id'],
        },
        handler: (args) async {
          final id = (args['id'] as String?)?.trim() ?? '';
          if (id.isEmpty) {
            return _result(<String, dynamic>{'ok': false, 'error': 'id required'},
                isError: true);
          }
          await store.delete('channel.cred/$id');
          final ids = await readIds()
            ..remove(id);
          await store.write(idsKey, jsonEncode(ids));
          return _result(<String, dynamic>{'ok': true, 'id': id},
              isError: false);
        },
      ),
    );
  }

  return exposed;
}

/// [MessageProcessor] that answers an inbound message with the host agent.
/// The event's `conversationId` names the target agent (the same id
/// `channel_notify` addresses as recipient). A failed ask is surfaced as a
/// plain reply so the loop always completes.
class _AgentMessageProcessor implements MessageProcessor {
  _AgentMessageProcessor(this._askAgent, this._bindings);

  final Future<String> Function(String agentId, String message) _askAgent;

  /// conversationId → target agentId. External platforms carry native
  /// conversation ids, so a binding routes them to an agent; the in-app feed
  /// uses conversationId == agentId, so an unbound conversation falls back to
  /// itself. Owned by the host (see `registerChannelCapability`), mutated by
  /// `channel.bind` / `channel.unbind`.
  final Map<String, String> _bindings;

  @override
  Future<ProcessResult> process(ChannelEvent event, Session session) async {
    final text = event.text ?? '';
    if (text.isEmpty) return ProcessResult.ignore();
    final convId = event.conversation.conversationId;
    final agentId = _bindings[convId] ?? convId;
    String reply;
    try {
      reply = await _askAgent(agentId, text);
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
