/// Unit tests for `VibeChatController` — dispatch routing, turn
/// accumulation, seed/clear, listener notifications, and
/// onTurnPersisted callbacks.
///
/// Routing contract: `ask()` routes to `sendForAgent(agentId, text)` when
/// `selectedAgentId != 'manager'` AND `sendForAgent` is non-null; it falls
/// back to `send(text)` in all other cases (manager selected, sendForAgent
/// null, or both).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/chat/chat_controller.dart';
import 'package:appplayer_studio/src/base/chat/chat_turn.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ChatTurn _reply(String text) => ChatTurn(role: 'assistant', text: text);

ChatTurn _agentReply(String text) => ChatTurn(role: 'assistant', text: text);

/// Build a controller whose `send` returns [sendReply] and whose
/// `sendForAgent` returns [agentReply] (if supplied).
VibeChatController _ctrl({
  String sendReply = 'ok',
  String agentReply = 'agent-ok',
  bool hasSendForAgent = true,
  List<String>? persistLog,
  List<void>? clearLog,
  List<ChatTurn>? removeLog,
}) {
  Future<ChatTurn> send(String text) async => _reply(sendReply);
  Future<ChatTurn> sendForAgentFn(String id, String text) async =>
      _agentReply(agentReply);

  return VibeChatController(
    send: send,
    sendForAgent: hasSendForAgent ? sendForAgentFn : null,
    onTurnPersisted:
        persistLog == null
            ? null
            : (t) async {
              persistLog.add(t.text);
            },
    onClearLog:
        clearLog == null
            ? null
            : () async {
              clearLog.add(null);
            },
    onRemoveTurn:
        removeLog == null
            ? null
            : (t) async {
              removeLog.add(t);
            },
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ---- routing -----------------------------------------------------------

  group('ask() routing: manager vs agent', () {
    test('default selectedAgentId is manager', () {
      final c = _ctrl();
      expect(c.selectedAgentId, 'manager');
    });

    test('selectedAgentId == manager → send() is used', () async {
      int sendHits = 0;
      int agentHits = 0;
      final c = VibeChatController(
        send: (text) async {
          sendHits++;
          return _reply('via-send');
        },
        sendForAgent: (id, text) async {
          agentHits++;
          return _agentReply('via-agent');
        },
      );
      // selectedAgentId == 'manager' by default
      await c.ask('hello');
      expect(sendHits, 1, reason: 'send should be called for manager');
      expect(agentHits, 0, reason: 'sendForAgent must not be called');
      expect(c.turns.last.text, 'via-send');
    });

    test('selectedAgentId != manager → sendForAgent() is used', () async {
      int sendHits = 0;
      String? capturedAgentId;
      String? capturedText;
      final c = VibeChatController(
        send: (text) async {
          sendHits++;
          return _reply('via-send');
        },
        sendForAgent: (id, text) async {
          capturedAgentId = id;
          capturedText = text;
          return _agentReply('via-agent');
        },
      );
      c.selectedAgentId = 'ux_designer';
      await c.ask('redesign header');
      expect(
        sendHits,
        0,
        reason: 'send must not be called when agent selected',
      );
      expect(capturedAgentId, 'ux_designer');
      expect(capturedText, 'redesign header');
      expect(c.turns.last.text, 'via-agent');
    });

    test(
      'selectedAgentId != manager BUT sendForAgent is null → falls back to send()',
      () async {
        int sendHits = 0;
        final c = VibeChatController(
          send: (text) async {
            sendHits++;
            return _reply('fallback');
          },
          // sendForAgent intentionally omitted — null
        );
        c.selectedAgentId = 'ux_designer';
        await c.ask('test');
        expect(
          sendHits,
          1,
          reason: 'no sendForAgent → must fall through to send',
        );
        expect(c.turns.last.text, 'fallback');
      },
    );

    test('selectedAgentId forwards the exact id to sendForAgent', () async {
      const kId = 'backend.agent';
      String? receivedId;
      final c = VibeChatController(
        send: (_) async => _reply('x'),
        sendForAgent: (id, text) async {
          receivedId = id;
          return _agentReply('y');
        },
      );
      c.selectedAgentId = kId;
      await c.ask('anything');
      expect(receivedId, kId);
    });
  });

  // ---- turns / busy ------------------------------------------------------

  group('ask() turn accumulation + busy flag', () {
    test('adds user turn then assistant turn', () async {
      final c = _ctrl(sendReply: 'hello back');
      await c.ask('hello');
      expect(c.turns.length, 2);
      expect(c.turns[0].role, 'user');
      expect(c.turns[0].text, 'hello');
      expect(c.turns[1].role, 'assistant');
      expect(c.turns[1].text, 'hello back');
    });

    test('busy is false before and after ask()', () async {
      final c = _ctrl();
      expect(c.busy, isFalse);
      final f = c.ask('hi');
      // During the async gap busy is true — we cannot observe it
      // synchronously without microtask manipulation, but we verify
      // it resets to false after the future resolves.
      await f;
      expect(c.busy, isFalse);
    });

    test('empty or whitespace-only input is ignored', () async {
      final c = _ctrl();
      await c.ask('   ');
      await c.ask('');
      expect(c.turns, isEmpty);
    });

    test('second ask() while busy is dropped (busy guard)', () async {
      // Build a controller whose send is a slow future.
      final completer = Future<ChatTurn>.delayed(
        const Duration(milliseconds: 10),
        () => _reply('slow'),
      );
      int sendCalls = 0;
      final c = VibeChatController(
        send: (_) async {
          sendCalls++;
          return completer;
        },
      );
      final f1 = c.ask('first');
      final f2 = c.ask('second'); // should be dropped because busy==true
      await Future.wait([f1, f2]);
      // Only one send call and only 2 turns (user + assistant for first)
      expect(sendCalls, 1);
      expect(c.turns.length, 2);
      expect(c.turns[0].text, 'first');
    });

    test('turns list is unmodifiable', () {
      final c = _ctrl();
      expect(
        () => (c.turns as List<ChatTurn>).add(_reply('x')),
        throwsUnsupportedError,
      );
    });
  });

  // ---- selectedAgentId notifier ------------------------------------------

  group('selectedAgentId notifier', () {
    test('setting same id does not fire listeners', () {
      final c = _ctrl();
      var hits = 0;
      c.addListener(() => hits++);
      c.selectedAgentId = 'manager'; // same value
      expect(hits, 0);
    });

    test('setting different id fires listeners', () {
      final c = _ctrl();
      var hits = 0;
      c.addListener(() => hits++);
      c.selectedAgentId = 'ux_designer';
      expect(hits, 1);
    });

    test('setting back to manager fires listeners again', () {
      final c = _ctrl();
      var hits = 0;
      c.addListener(() => hits++);
      c.selectedAgentId = 'ux_designer';
      c.selectedAgentId = 'manager';
      expect(hits, 2);
    });
  });

  // ---- seed / clear / removeTurn -----------------------------------------

  group('seed()', () {
    test('replaces existing turns and notifies', () {
      final c = _ctrl();
      final initial = [
        ChatTurn(role: 'user', text: 'old'),
        ChatTurn(role: 'assistant', text: 'reply'),
      ];
      c.seed(initial);
      expect(c.turns.length, 2);

      final fresh = [ChatTurn(role: 'user', text: 'fresh')];
      var hits = 0;
      c.addListener(() => hits++);
      c.seed(fresh);
      expect(c.turns.length, 1);
      expect(c.turns.first.text, 'fresh');
      expect(hits, 1);
    });

    test('seed with empty iterable clears turns', () {
      final c = _ctrl();
      c.seed([ChatTurn(role: 'user', text: 'x')]);
      c.seed([]);
      expect(c.turns, isEmpty);
    });
  });

  group('clear()', () {
    test('removes all turns and notifies', () async {
      final c = _ctrl();
      c.seed([
        ChatTurn(role: 'user', text: 'a'),
        ChatTurn(role: 'assistant', text: 'b'),
      ]);
      var hits = 0;
      c.addListener(() => hits++);
      await c.clear();
      expect(c.turns, isEmpty);
      expect(hits, greaterThanOrEqualTo(1));
    });

    test('fires onClearLog callback', () async {
      final log = <void>[];
      final c = _ctrl(clearLog: log);
      c.seed([ChatTurn(role: 'user', text: 'a')]);
      await c.clear();
      expect(log, hasLength(1));
    });

    test('onClearLog throwing is swallowed (best-effort)', () async {
      final c = VibeChatController(
        send: (_) async => _reply('x'),
        onClearLog: () async {
          throw Exception('disk error');
        },
      );
      c.seed([ChatTurn(role: 'user', text: 'a')]);
      // Must not throw
      await expectLater(c.clear(), completes);
      expect(c.turns, isEmpty);
    });

    test('clear with null onClearLog succeeds silently', () async {
      final c = _ctrl(clearLog: null);
      c.seed([ChatTurn(role: 'user', text: 'a')]);
      await c.clear();
      expect(c.turns, isEmpty);
    });
  });

  group('removeTurn()', () {
    test('removes the exact turn and notifies', () async {
      final c = _ctrl();
      final t1 = ChatTurn(role: 'user', text: 'first');
      final t2 = ChatTurn(role: 'assistant', text: 'second');
      c.seed([t1, t2]);
      var hits = 0;
      c.addListener(() => hits++);
      await c.removeTurn(t1);
      expect(c.turns, [t2]);
      expect(hits, 1);
    });

    test('removing a non-existent turn is a no-op (no notify)', () async {
      final c = _ctrl();
      final orphan = ChatTurn(role: 'user', text: 'orphan');
      final kept = ChatTurn(role: 'user', text: 'kept');
      c.seed([kept]);
      var hits = 0;
      c.addListener(() => hits++);
      await c.removeTurn(orphan);
      expect(c.turns, [kept]);
      expect(hits, 0);
    });

    test('fires onRemoveTurn callback with the removed turn', () async {
      final removed = <ChatTurn>[];
      final c = _ctrl(removeLog: removed);
      final t = ChatTurn(role: 'user', text: 'bye');
      c.seed([t]);
      await c.removeTurn(t);
      expect(removed, hasLength(1));
      expect(removed.first, same(t));
    });

    test('onRemoveTurn throwing is swallowed (best-effort)', () async {
      final t = ChatTurn(role: 'user', text: 'x');
      final c = VibeChatController(
        send: (_) async => _reply('y'),
        onRemoveTurn: (_) async {
          throw Exception('io fail');
        },
      );
      c.seed([t]);
      await expectLater(c.removeTurn(t), completes);
      expect(c.turns, isEmpty);
    });
  });

  // ---- appendTurn --------------------------------------------------------

  group('appendTurn()', () {
    test('appends a turn and notifies', () {
      final c = _ctrl();
      var hits = 0;
      c.addListener(() => hits++);
      final t = ChatTurn(role: 'assistant.patch', text: 'patch card');
      c.appendTurn(t);
      expect(c.turns, [t]);
      expect(hits, 1);
    });

    test('fires onTurnPersisted for appended turns', () {
      final log = <String>[];
      final c = _ctrl(persistLog: log);
      c.appendTurn(ChatTurn(role: 'assistant', text: 'inline'));
      expect(log, ['inline']);
    });
  });

  // ---- onTurnPersisted ---------------------------------------------------

  group('onTurnPersisted during ask()', () {
    test('user turn and assistant turn both reach onTurnPersisted', () async {
      final log = <String>[];
      final c = _ctrl(persistLog: log, sendReply: 'assistant-text');
      await c.ask('user-text');
      expect(log, ['user-text', 'assistant-text']);
    });

    test('agent path also persists both turns', () async {
      final log = <String>[];
      final c = _ctrl(persistLog: log, agentReply: 'agent-text');
      c.selectedAgentId = 'writer';
      await c.ask('write me something');
      expect(log, ['write me something', 'agent-text']);
    });
  });

  // ---- agents list -------------------------------------------------------

  group('agents list', () {
    test('empty agents by default', () {
      expect(_ctrl().agents, isEmpty);
    });

    test('agents list is exposed as-is', () {
      final entries = [
        const VibeChatAgentEntry(id: 'a1', displayName: 'Alpha'),
        const VibeChatAgentEntry(
          id: 'a2',
          displayName: 'Beta',
          modelId: 'gpt-4o',
        ),
      ];
      final c = VibeChatController(
        send: (_) async => _reply('x'),
        agents: entries,
      );
      expect(c.agents, entries);
      expect(c.agents[1].modelId, 'gpt-4o');
    });
  });

  // ---- VibeChatAgentEntry ------------------------------------------------

  group('VibeChatAgentEntry', () {
    test('modelId defaults to null when omitted', () {
      const e = VibeChatAgentEntry(id: 'x', displayName: 'X');
      expect(e.modelId, isNull);
    });

    test('modelId is preserved when supplied', () {
      const e = VibeChatAgentEntry(
        id: 'y',
        displayName: 'Y',
        modelId: 'claude-3',
      );
      expect(e.modelId, 'claude-3');
    });
  });
}
