/// `registerChannelCapability` — locks the host's `channel.*` wiring over a
/// [HostToolRegistry]: the always-on in-app connector (backed by a real
/// [KvStoragePortAdapter]), the `list/status/send/session.history/receive`
/// surface, the `bind/unbind/bindings` inbound-routing map (project-KV
/// persisted), the P2 agentic loop (`askAgent` → `_AgentMessageProcessor` →
/// reply posted back to the feed), the P3 `connect`/`disconnect` external
/// connector surface (error paths only — no live network), and the optional
/// `credential_*` vault surface gated on a [SecureStorage].
///
/// Drives everything through `InProcessKernelServerHost.callTool` (the same
/// dispatch path production uses), matching the
/// `browser_capability_test.dart` pattern. `channel.send` is `destructive:
/// true`, so a `confirmDestructive` callback approving every call is wired
/// unless a test is specifically locking the deny-by-default gate.
///
/// Live-infra external connectors (slack/telegram/kakao/email `start()`,
/// which perform real network I/O) are NOT exercised — only the error paths
/// reachable before any socket/HTTP call (`bad_args` / `unknown_platform` /
/// `missing_param` / `exists`), per the "skip brittle live-infra" rule.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart'
    show InMemorySecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/src/base/install/channel_capability.dart';

Map<String, dynamic> _json(mk.KernelToolResult r) {
  final text = r.content.whereType<mk.KernelTextContent>().first.text;
  return jsonDecode(text) as Map<String, dynamic>;
}

mk.HostToolRegistry _registry(
  mk.InProcessKernelServerHost boot, {
  mk.ConfirmDestructive? confirmDestructive,
}) => mk.HostToolRegistry(
  endpoint: boot,
  attachToDispatcher: (_, _) {},
  detachFromDispatcher: (_) {},
  confirmDestructive: confirmDestructive,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late mk.KvStoragePortAdapter kv;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('channel_cap_test_');
    kv = mk.KvStoragePortAdapter(rootDir: tmp.path, workspaceId: 'ws1');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('surface — no secure, no askAgent', () {
    test('exposes list/status/send/session.history/receive/bind/unbind/'
        'bindings/connect/disconnect, no credential_* verbs', () {
      final boot = mk.InProcessKernelServerHost();
      final exposed = registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
      );
      expect(
        exposed.toSet(),
        containsAll(<String>[
          'channel.list',
          'channel.status',
          'channel.send',
          'channel.session.history',
          'channel.receive',
          'channel.bind',
          'channel.unbind',
          'channel.bindings',
          'channel.connect',
          'channel.disconnect',
        ]),
      );
      expect(
        exposed.where((n) => n.startsWith('channel.credential_')),
        isEmpty,
        reason: 'no SecureStorage wired → no credential vault surface',
      );
      final landed = boot.toolDefinitions.map((t) => t.name).toSet();
      for (final n in exposed) {
        expect(landed, contains(n), reason: '$n reported but not registered');
      }
    });
  });

  group('surface — secure wired', () {
    test('adds credential_set/credential_ids/credential_remove', () {
      final boot = mk.InProcessKernelServerHost();
      final exposed = registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
        secure: InMemorySecureStorage(),
      );
      expect(
        exposed.toSet(),
        containsAll(<String>[
          'channel.credential_set',
          'channel.credential_ids',
          'channel.credential_remove',
        ]),
      );
    });
  });

  group('list/status — built-in in-app connector', () {
    test('list reports in_app connected + running immediately', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
      );
      final out = _json(await boot.callTool('channel.list', const {}));
      expect(out['ok'], isTrue);
      final channels = (out['channels'] as List).cast<Map>();
      final inApp = channels.singleWhere((c) => c['channelId'] == 'in_app');
      expect(inApp['platform'], 'in_app');
      expect(inApp['running'], isTrue);
    });

    test('status: unknown channelId → channel.not_found', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
      );
      final r = await boot.callTool('channel.status', const {
        'channelId': 'nope',
      });
      expect(r.isError, isTrue);
      final out = _json(r);
      expect(out['ok'], isFalse);
      expect(out['code'], 'channel.not_found');
    });

    test('status: in_app → ok:true platform+running', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
      );
      final out = _json(
        await boot.callTool('channel.status', const {'channelId': 'in_app'}),
      );
      expect(out['ok'], isTrue);
      expect(out['platform'], 'in_app');
      expect(out['running'], isTrue);
    });
  });

  group('send — destructive gate', () {
    test(
      'blocked (deny-by-default) with no confirmDestructive callback wired',
      () async {
        final boot = mk.InProcessKernelServerHost();
        registerChannelCapability(
          registry: _registry(boot), // no confirmDestructive
          kv: () => kv,
          facts: () => null,
        );
        final r = await boot.callTool('channel.send', const {
          'conversationId': 'c1',
          'text': 'hi',
        });
        expect(r.isError, isTrue);
        final out = _json(r);
        expect(out['ok'], isFalse);
        expect(out['error'], 'destructive_action_blocked');
      },
    );

    test('approved: no active project → channel.no_project', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot, confirmDestructive: (_, _) async => true),
        kv: () => null, // no active project
        facts: () => null,
      );
      final r = await boot.callTool('channel.send', const {
        'conversationId': 'c1',
        'text': 'hi',
      });
      expect(r.isError, isTrue);
      final out = _json(r);
      expect(out['ok'], isFalse);
      // `send`'s error envelope carries the SendResult's error MESSAGE (not
      // a code) — `_persist` returning null surfaces as this string.
      expect(out['error'], 'no active project');
    });

    test(
      'approved: active project → persists to KV under ws/<id>/messages/*',
      () async {
        final boot = mk.InProcessKernelServerHost();
        registerChannelCapability(
          registry: _registry(boot, confirmDestructive: (_, _) async => true),
          kv: () => kv,
          facts: () => null,
        );
        final out = _json(
          await boot.callTool('channel.send', const {
            'conversationId': 'c1',
            'text': 'hello feed',
          }),
        );
        expect(out['ok'], isTrue);
        expect(out['success'], isTrue);
        final messageId = out['messageId'] as String;
        final stored = await kv.get('ws/ws1/messages/$messageId');
        expect(stored, isA<Map>());
        expect((stored as Map)['role'], 'assistant');
        expect(stored['text'], 'hello feed');
        expect(stored['conversationId'], 'c1');
      },
    );

    test('unknown channelId → channel.not_found', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot, confirmDestructive: (_, _) async => true),
        kv: () => kv,
        facts: () => null,
      );
      final out = _json(
        await boot.callTool('channel.send', const {
          'channelId': 'nope',
          'conversationId': 'c1',
          'text': 'hi',
        }),
      );
      expect(out['ok'], isFalse);
      expect(out['code'], 'channel.not_found');
    });
  });

  group('session.history', () {
    test('no active project → channel.no_project', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot, confirmDestructive: (_, _) async => true),
        kv: () => null,
        facts: () => null,
      );
      final r = await boot.callTool('channel.session.history', const {});
      expect(r.isError, isTrue);
      expect(_json(r)['code'], 'channel.no_project');
    });

    test('filters by conversationId and respects limit', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot, confirmDestructive: (_, _) async => true),
        kv: () => kv,
        facts: () => null,
      );
      for (var i = 0; i < 3; i++) {
        await boot.callTool('channel.send', <String, dynamic>{
          'conversationId': 'convo-a',
          'text': 'a$i',
        });
      }
      await boot.callTool('channel.send', const {
        'conversationId': 'convo-b',
        'text': 'b0',
      });

      final all = _json(
        await boot.callTool('channel.session.history', const {}),
      );
      expect(all['ok'], isTrue);
      expect((all['messages'] as List).length, 4);

      final filtered = _json(
        await boot.callTool('channel.session.history', const {
          'conversationId': 'convo-a',
        }),
      );
      final msgs = (filtered['messages'] as List).cast<Map>();
      expect(msgs.length, 3);
      expect(msgs.every((m) => m['conversationId'] == 'convo-a'), isTrue);

      final limited = _json(
        await boot.callTool('channel.session.history', const {
          'conversationId': 'convo-a',
          'limit': 1,
        }),
      );
      expect((limited['messages'] as List).length, 1);
    });
  });

  group('receive — non-agentic (no askAgent wired)', () {
    test('no active project → channel.no_project', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => null,
        facts: () => null,
      );
      final r = await boot.callTool('channel.receive', const {
        'conversationId': 'agent-1',
        'text': 'hello',
      });
      expect(r.isError, isTrue);
      expect(_json(r)['code'], 'channel.no_project');
    });

    test(
      'persists the inbound message as role:user, agentic:false, no reply',
      () async {
        final boot = mk.InProcessKernelServerHost();
        registerChannelCapability(
          registry: _registry(boot, confirmDestructive: (_, _) async => true),
          kv: () => kv,
          facts: () => null,
        );
        final out = _json(
          await boot.callTool('channel.receive', const {
            'conversationId': 'agent-1',
            'text': 'hello',
          }),
        );
        expect(out['ok'], isTrue);
        expect(out['agentic'], isFalse);
        final messageId = out['messageId'] as String;
        final stored = await kv.get('ws/ws1/messages/$messageId');
        expect((stored as Map)['role'], 'user');

        // No ChannelHandler attached (no askAgent) → nothing else appears.
        final history = _json(
          await boot.callTool('channel.session.history', const {}),
        );
        expect((history['messages'] as List).length, 1);
      },
    );
  });

  group('receive — agentic (askAgent wired, P2)', () {
    // The ChannelHandler pipeline answers asynchronously. Wait until the
    // reply is on record — its write has then finished, so neither the
    // assertions nor tearDown's delete race the pending persist (a fixed
    // 50 ms was not enough under full-suite load).
    Future<void> untilReplied(
      mk.InProcessKernelServerHost boot,
      String conversationId,
    ) async {
      for (var i = 0; i < 200; i++) {
        final history = _json(
          await boot.callTool('channel.session.history', {
            'conversationId': conversationId,
          }),
        );
        final msgs = (history['messages'] as List).cast<Map>();
        if (msgs.any((m) => m['role'] == 'assistant')) return;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    test('inbound routes to the agent named by conversationId (unbound '
        'fallback) and the reply is posted back to the feed', () async {
      final calls = <List<String>>[];
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot, confirmDestructive: (_, _) async => true),
        kv: () => kv,
        facts: () => null,
        askAgent: (agentId, message) async {
          calls.add([agentId, message]);
          return 'reply from $agentId';
        },
      );
      // Let the unawaited ChannelHandler.start() subscription land.
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final out = _json(
        await boot.callTool('channel.receive', const {
          'conversationId': 'agent-x',
          'text': 'ping',
        }),
      );
      expect(out['ok'], isTrue);
      expect(out['agentic'], isTrue);

      await untilReplied(boot, 'agent-x');

      expect(calls, hasLength(1));
      expect(calls.single, ['agent-x', 'ping']);

      final history = _json(
        await boot.callTool('channel.session.history', const {
          'conversationId': 'agent-x',
        }),
      );
      final msgs = (history['messages'] as List).cast<Map>();
      expect(msgs.length, 2);
      expect(
        msgs.any((m) => m['role'] == 'user' && m['text'] == 'ping'),
        isTrue,
      );
      expect(
        msgs.any(
          (m) => m['role'] == 'assistant' && m['text'] == 'reply from agent-x',
        ),
        isTrue,
      );
    });

    test(
      'bound conversation routes to the bound agentId, not itself',
      () async {
        final calls = <String>[];
        final boot = mk.InProcessKernelServerHost();
        registerChannelCapability(
          registry: _registry(boot, confirmDestructive: (_, _) async => true),
          kv: () => kv,
          facts: () => null,
          askAgent: (agentId, message) async {
            calls.add(agentId);
            return 'ack';
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await boot.callTool('channel.bind', const {
          'conversationId': 'room-42',
          'agentId': 'ops-manager',
        });
        await boot.callTool('channel.receive', const {
          'conversationId': 'room-42',
          'text': 'hi',
        });
        await untilReplied(boot, 'room-42');

        expect(calls, ['ops-manager']);
      },
    );

    test(
      'a failed askAgent still completes the loop with an error reply',
      () async {
        final boot = mk.InProcessKernelServerHost();
        registerChannelCapability(
          registry: _registry(boot, confirmDestructive: (_, _) async => true),
          kv: () => kv,
          facts: () => null,
          askAgent:
              (agentId, message) async => throw StateError('agent unreachable'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await boot.callTool('channel.receive', const {
          'conversationId': 'agent-y',
          'text': 'ping',
        });
        await untilReplied(boot, 'agent-y');

        final history = _json(
          await boot.callTool('channel.session.history', const {
            'conversationId': 'agent-y',
          }),
        );
        final msgs = (history['messages'] as List).cast<Map>();
        final reply = msgs.singleWhere((m) => m['role'] == 'assistant');
        expect(reply['text'], contains('agent error'));
        expect(reply['text'], contains('agent unreachable'));
      },
    );
  });

  group('bind / unbind / bindings', () {
    test('bind requires both conversationId and agentId', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
      );
      final r = await boot.callTool('channel.bind', const {
        'conversationId': 'c1',
      });
      expect(r.isError, isTrue);
      expect(_json(r)['ok'], isFalse);
    });

    test(
      'bind → bindings lists it → unbind removes it, persisted to KV',
      () async {
        final boot = mk.InProcessKernelServerHost();
        registerChannelCapability(
          registry: _registry(boot),
          kv: () => kv,
          facts: () => null,
        );
        final bindOut = _json(
          await boot.callTool('channel.bind', const {
            'conversationId': 'c1',
            'agentId': 'a1',
          }),
        );
        expect(bindOut['ok'], isTrue);

        final listed = _json(await boot.callTool('channel.bindings', const {}));
        final entries = (listed['bindings'] as List).cast<Map>();
        // Map `==` is identity, not deep — assert on the fields directly.
        expect(
          entries.any(
            (e) => e['conversationId'] == 'c1' && e['agentId'] == 'a1',
          ),
          isTrue,
        );

        // Persisted to project KV.
        final persisted = await kv.get('channel/inbound_bindings');
        expect((persisted as Map)['c1'], 'a1');

        final unbindOut = _json(
          await boot.callTool('channel.unbind', const {'conversationId': 'c1'}),
        );
        expect(unbindOut['removed'], isTrue);

        final listedAfter = _json(
          await boot.callTool('channel.bindings', const {}),
        );
        expect((listedAfter['bindings'] as List), isEmpty);

        final persistedAfter = await kv.get('channel/inbound_bindings');
        expect((persistedAfter as Map).containsKey('c1'), isFalse);
      },
    );

    test('unbind of a never-bound conversationId → removed:false', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
      );
      final out = _json(
        await boot.callTool('channel.unbind', const {
          'conversationId': 'ghost',
        }),
      );
      expect(out['ok'], isTrue);
      expect(out['removed'], isFalse);
    });

    test('bindings hydrate from KV on a fresh registration (reboot)', () async {
      final bootA = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(bootA),
        kv: () => kv,
        facts: () => null,
      );
      await bootA.callTool('channel.bind', const {
        'conversationId': 'c9',
        'agentId': 'a9',
      });

      // Fresh host + fresh registration over the SAME kv — simulates a
      // reboot. Give the best-effort hydrate a beat to complete.
      final bootB = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(bootB),
        kv: () => kv,
        facts: () => null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final listed = _json(await bootB.callTool('channel.bindings', const {}));
      final entries = (listed['bindings'] as List).cast<Map>();
      expect(
        entries.any((e) => e['conversationId'] == 'c9' && e['agentId'] == 'a9'),
        isTrue,
      );
    });
  });

  group('connect / disconnect — error paths only (no live network)', () {
    test('missing platform/id → channel.bad_args', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
      );
      final out = _json(
        await boot.callTool('channel.connect', const {'id': 'x'}),
      );
      expect(out['ok'], isFalse);
      expect(out['code'], 'channel.bad_args');
    });

    test('unknown platform → unknown_platform (no builder invoked)', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
      );
      final out = _json(
        await boot.callTool('channel.connect', const {
          'platform': 'not-a-real-platform',
          'id': 'x1',
        }),
      );
      expect(out['ok'], isFalse);
      expect(out['code'], 'unknown_platform');
    });

    test(
      'missing required param (slack w/o botToken) → missing_param',
      () async {
        final boot = mk.InProcessKernelServerHost();
        registerChannelCapability(
          registry: _registry(boot),
          kv: () => kv,
          facts: () => null,
        );
        final out = _json(
          await boot.callTool('channel.connect', const {
            'platform': 'slack',
            'id': 'sl1',
          }),
        );
        expect(out['ok'], isFalse);
        expect(out['code'], 'missing_param');
      },
    );

    test(
      'connect id already in the live connectors map → channel.exists',
      () async {
        final boot = mk.InProcessKernelServerHost();
        registerChannelCapability(
          registry: _registry(boot),
          kv: () => kv,
          facts: () => null,
        );
        final out = _json(
          await boot.callTool('channel.connect', const {
            'platform': 'slack',
            'id': 'in_app', // the built-in connector already occupies this id
          }),
        );
        expect(out['ok'], isFalse);
        expect(out['code'], 'channel.exists');
      },
    );

    test('disconnect: missing id → channel.bad_args; unknown id → '
        'channel.not_found', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
      );
      final missing = _json(
        await boot.callTool('channel.disconnect', const {}),
      );
      expect(missing['code'], 'channel.bad_args');

      final notFound = _json(
        await boot.callTool('channel.disconnect', const {'id': 'ghost'}),
      );
      expect(notFound['code'], 'channel.not_found');
    });
  });

  group('credential vault — set / ids / remove, no plaintext read-back', () {
    test('set → credential_ids lists id + field names only', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
        secure: InMemorySecureStorage(),
      );
      final setOut = _json(
        await boot.callTool('channel.credential_set', const {
          'id': 'sl1',
          'platform': 'slack',
          'params': {'botToken': 'xoxb-secret', 'signingSecret': 'shh'},
        }),
      );
      expect(setOut['ok'], isTrue);
      expect(setOut['id'], 'sl1');
      expect((setOut['fields'] as List).toSet(), {'botToken', 'signingSecret'});
      // The secret VALUES never appear anywhere in the envelope.
      expect(jsonEncode(setOut), isNot(contains('xoxb-secret')));
      expect(jsonEncode(setOut), isNot(contains('shh')));

      final idsOut = _json(
        await boot.callTool('channel.credential_ids', const {}),
      );
      expect(idsOut['ids'], contains('sl1'));
    });

    test('set requires id and non-empty params', () async {
      final boot = mk.InProcessKernelServerHost();
      registerChannelCapability(
        registry: _registry(boot),
        kv: () => kv,
        facts: () => null,
        secure: InMemorySecureStorage(),
      );
      final out = _json(
        await boot.callTool('channel.credential_set', const {
          'id': 'x',
          'params': {},
        }),
      );
      expect(out['ok'], isFalse);
    });

    test(
      'remove: missing id → error; existing id removed from ids list',
      () async {
        final boot = mk.InProcessKernelServerHost();
        registerChannelCapability(
          registry: _registry(boot),
          kv: () => kv,
          facts: () => null,
          secure: InMemorySecureStorage(),
        );
        final missing = _json(
          await boot.callTool('channel.credential_remove', const {}),
        );
        expect(missing['ok'], isFalse);

        await boot.callTool('channel.credential_set', const {
          'id': 'sl2',
          'params': {'botToken': 't'},
        });
        final removeOut = _json(
          await boot.callTool('channel.credential_remove', const {'id': 'sl2'}),
        );
        expect(removeOut['ok'], isTrue);
        final idsAfter = _json(
          await boot.callTool('channel.credential_ids', const {}),
        );
        expect(idsAfter['ids'], isNot(contains('sl2')));
      },
    );
  });
}
