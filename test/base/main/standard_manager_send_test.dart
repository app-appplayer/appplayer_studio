/// Unit tests for `standardManagerSend` — the tool-use dispatch loop
/// in `standard_studio_shell.dart`.
///
/// `standardManagerSend` is a top-level async function callable without
/// Flutter widgets. The null-agentHost paths (ms1, ms8, ms9) need no boot.
/// The non-null paths boot a real KernelApp with a stub `mll.LlmProvider`
/// (from mcp_llm) wrapped in `fb.LlmPortAdapter.fromInterface`, so that
/// `host.askAgent()` returns canned replies without any network call.
///
/// Scenarios:
///   ms1  null agentHost → returns missingKeyMessage turn
///   ms8  custom missingKeyMessage forwarded on null host
///   ms9  returned ChatTurn has role='assistant'
///   ms2  null dispatchTool → single askAgent call, content returned
///   ms3  reply with no toolCalls → returns content turn immediately
///   ms4  reply with toolCalls → dispatches each tool, result fed back
///   ms5  second round has no toolCalls → terminates normally
///   ms6  maxIterations exceeded → returns abort message
///   ms7  dispatchTool throws → error captured as string, loop continues
library;

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as fb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_llm/mcp_llm.dart' as mll;
import 'package:appplayer_studio/src/base/agent/agent_host.dart';
import 'package:appplayer_studio/src/base/agent/agent_profile.dart';
import 'package:appplayer_studio/src/base/main/standard_studio_shell.dart';

// ---------------------------------------------------------------------------
// Stub mll.LlmProvider — returns pre-programmed replies without network calls
// ---------------------------------------------------------------------------

/// A minimal `mll.LlmProvider` that cycles through a queue of canned
/// `mll.LlmResponse` values. Consuming tests use `_withToolCall()` or
/// `_plainText()` helpers to build the queue.
class _StubMllProvider implements mll.LlmProvider {
  _StubMllProvider(this._queue);

  final List<mll.LlmResponse> _queue;
  int _idx = 0;

  mll.LlmResponse _next() =>
      _idx < _queue.length ? _queue[_idx++] : _queue.last;

  @override
  Future<void> initialize(mll.LlmConfiguration config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<mll.LlmResponse> complete(mll.LlmRequest request) async => _next();

  @override
  Stream<mll.LlmResponseChunk> streamComplete(mll.LlmRequest request) async* {
    final r = _next();
    yield mll.LlmResponseChunk(textChunk: r.text, isDone: true);
  }

  @override
  Future<List<double>> getEmbeddings(String text) async => const [];

  @override
  bool hasToolCallMetadata(Map<String, dynamic> metadata) => false;

  @override
  mll.LlmToolCall? extractToolCallFromMetadata(Map<String, dynamic> metadata) =>
      null;

  @override
  Map<String, dynamic> standardizeMetadata(Map<String, dynamic> metadata) =>
      metadata;

  @override
  bool get supportsPromptCaching => false;
}

// ---------------------------------------------------------------------------
// Helpers to build canned LLM replies
// ---------------------------------------------------------------------------

/// Plain-text reply — no tool calls.
mll.LlmResponse _plainText(String text) =>
    mll.LlmResponse(text: text, metadata: const {});

/// Reply with a single tool call.
mll.LlmResponse _withToolCall(
  String name,
  Map<String, dynamic> args, {
  String text = '',
}) => mll.LlmResponse(
  text: text,
  metadata: const {},
  toolCalls: [mll.LlmToolCall(name: name, arguments: args)],
);

// ---------------------------------------------------------------------------
// Boot helpers
// ---------------------------------------------------------------------------

/// Boots a minimal KernelApp with the stub LLM provider keyed as 'stub'.
Future<(Directory, fb.KernelApp)> _bootKernel(
  List<mll.LlmResponse> queue,
) async {
  final tmp = await Directory.systemTemp.createTemp('sms_test_');
  final stub = _StubMllProvider(queue);
  final adapter = fb.LlmPortAdapter.fromInterface(
    modelId: 'stub-1',
    provider: stub,
    providerName: 'stub',
  );
  final app = await fb.KernelApp.boot(
    workspaceId: 'sms_test',
    kvStorage: fb.KvStoragePortAdapter(rootDir: tmp.path),
    bundleRegistryStorageDir: tmp.path,
    llmProviders: {'stub': adapter},
  );
  return (tmp, app);
}

/// Constructs and registers an AgentHost backed by [app].
Future<AgentHost> _buildHost(fb.KernelApp app) async {
  final host = AgentHost(
    flowbrain: app,
    workspaceId: 'sms_test',
    fetchAllToolDefinitions: () => const [],
    profiles: [
      VibeAgentProfile(
        id: 'manager',
        displayName: 'Test Manager',
        role: fb.AgentRole.manager,
        modelId: 'stub-1',
        provider: 'stub',
        systemPrompt: 'You are a test agent.',
        toolNames: const [],
      ),
    ],
  );
  await host.registerAgents();
  return host;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ── Null-host paths — no boot needed ─────────────────────────────────────
  group('standardManagerSend (no-host)', () {
    test('ms1 null agentHost returns missingKeyMessage turn', () async {
      final turn = await standardManagerSend(
        agentHost: null,
        input: 'hello',
        missingKeyMessage: 'No key set.',
      );
      expect(turn.role, 'assistant');
      expect(turn.text, 'No key set.');
    });

    test('ms8 custom missingKeyMessage forwarded on null host', () async {
      final turn = await standardManagerSend(
        agentHost: null,
        input: 'x',
        missingKeyMessage: 'Custom message here.',
      );
      expect(turn.text, 'Custom message here.');
    });

    test('ms9 returned ChatTurn has role=assistant', () async {
      final turn = await standardManagerSend(agentHost: null, input: 'x');
      expect(turn.role, 'assistant');
    });
  });

  // ── Non-null host — stub LLM via real KernelApp ───────────────────────────
  group('standardManagerSend (with stub host)', () {
    // Each test boots its own isolated kernel so stub index starts fresh.

    test('ms2 null dispatchTool calls askAgent and returns content', () async {
      final (td, ka) = await _bootKernel([_plainText('Direct reply')]);
      addTearDown(() async {
        try {
          await td.delete(recursive: true);
        } catch (_) {}
      });
      final host = await _buildHost(ka);

      final turn = await standardManagerSend(
        agentHost: host,
        input: 'what is 2+2?',
        dispatchTool: null,
      );
      expect(turn.text, 'Direct reply');
    });

    test('ms3 reply with no toolCalls returns content immediately', () async {
      final (td, ka) = await _bootKernel([_plainText('Hello from LLM')]);
      addTearDown(() async {
        try {
          await td.delete(recursive: true);
        } catch (_) {}
      });
      final host = await _buildHost(ka);

      final turn = await standardManagerSend(
        agentHost: host,
        input: 'ping',
        // dispatchTool present but reply has no tool calls → exits on round 0
        dispatchTool: (name, args) async => 'should_not_be_called',
      );
      expect(turn.role, 'assistant');
      expect(turn.text, 'Hello from LLM');
    });

    test('ms4 tool calls dispatched and result fed back', () async {
      final (td, ka) = await _bootKernel([
        _withToolCall('bk.fact.get', {
          'key': 'weather',
        }, text: 'I need the fact.'),
        _plainText('Done!'),
      ]);
      addTearDown(() async {
        try {
          await td.delete(recursive: true);
        } catch (_) {}
      });
      final host = await _buildHost(ka);

      final capturedCalls = <String>[];
      final turn = await standardManagerSend(
        agentHost: host,
        input: 'get weather fact',
        dispatchTool: (name, args) async {
          capturedCalls.add(name);
          return 'fact_result';
        },
      );

      expect(capturedCalls, contains('bk.fact.get'));
      expect(turn.text, 'Done!');
    });

    test('ms5 terminates once round has no toolCalls', () async {
      final (td, ka) = await _bootKernel([
        _withToolCall('tool.a', {}),
        _plainText('All done'),
      ]);
      addTearDown(() async {
        try {
          await td.delete(recursive: true);
        } catch (_) {}
      });
      final host = await _buildHost(ka);

      var dispatchCount = 0;
      final turn = await standardManagerSend(
        agentHost: host,
        input: 'start',
        dispatchTool: (name, args) async {
          dispatchCount++;
          return 'ok';
        },
      );
      expect(dispatchCount, 1);
      expect(turn.text, 'All done');
    });

    test('ms6 maxIterations exceeded returns abort message', () async {
      // Provide 20 tool-call replies so each iteration sees one.
      final replies = List.generate(20, (_) => _withToolCall('tool.loop', {}));
      final (td, ka) = await _bootKernel(replies);
      addTearDown(() async {
        try {
          await td.delete(recursive: true);
        } catch (_) {}
      });
      final host = await _buildHost(ka);

      final turn = await standardManagerSend(
        agentHost: host,
        input: 'loop',
        dispatchTool: (name, args) async => 'partial',
        maxIterations: 3,
      );
      // Exact text: '(tool-use loop hit 3 iterations; aborting)'
      expect(turn.text, contains('3 iterations'));
      expect(turn.text, contains('aborting'));
    });

    test('ms7 dispatchTool throws — error captured, loop continues', () async {
      final (td, ka) = await _bootKernel([
        _withToolCall('bad.tool', {}),
        _plainText('Recovered'),
      ]);
      addTearDown(() async {
        try {
          await td.delete(recursive: true);
        } catch (_) {}
      });
      final host = await _buildHost(ka);

      final turn = await standardManagerSend(
        agentHost: host,
        input: 'risky',
        dispatchTool: (name, args) async {
          throw Exception('tool failed');
        },
      );
      // The loop catches the error and continues to the next round.
      expect(turn.text, 'Recovered');
    });
  });
}
