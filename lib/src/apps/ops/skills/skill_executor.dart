import 'dart:convert' show jsonDecode;
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;

import '../adapters/llm_adapter.dart';
import '../registries/knowledge_registry.dart';
import 'skill_definition.dart';

/// Executes a parsed [SkillDefinition] against the live engine.
///
/// Callers pass a [ctxActorId]/[ctxWorkspaceId] so the executor can record
/// agent-scoped provenance into FactGraph. The skill body itself is
/// assumed to already be the right agent-specific variant (resolved via
/// [SkillResolver] upstream).
/// Asks the connected MCP client to perform an LLM completion via the
/// `sampling/createMessage` flow (MCP 2.0+). Returns plain text. Throws
/// [StateError] if no client supports sampling.
typedef SamplingProvider =
    Future<String> Function({
      required String prompt,
      String? systemPrompt,
      double? temperature,
      int maxTokens,
    });

class SkillExecutor {
  SkillExecutor({required this.system});

  final KnowledgeSystem system;

  // ignore: unused_field
  LlmAdapter? _llm;
  KnowledgeRegistry? _knowledge;
  SamplingProvider? _sampling;

  /// Host `callTool` handle (`BuiltinToolRegistry` → host endpoint), bound by
  /// `McpInbound.registerToolsOn`. Lets skill steps invoke a host-owned
  /// capability (e.g. `browser.*`) instead of a built-in-owned engine —
  /// the parity rule. NOTE: not `system.infraPorts.mcp`, which routes to the
  /// *external* configured MCP servers, not the host's own tools.
  Future<KernelToolResult> Function(String name, Map<String, dynamic> args)?
  _hostCallTool;

  /// Whether *some* LLM is reachable — internal provider OR sampling.
  /// Used by [SystemTools] to gate skill_generate friendly errors.
  bool get hasAnyLlm => (_llm?.hasInternalLlm ?? false) || _sampling != null;

  /// Public access for tools (skill_generate) that need to perform a
  /// completion via whichever path is available.
  SamplingProvider? get samplingProvider => _sampling;

  void attachAdapters({required LlmAdapter llm, KnowledgeRegistry? knowledge}) {
    _llm = llm;
    _knowledge = knowledge;
  }

  /// Bind a sampling fallback. main.dart wires this after the inbound
  /// MCP transports come up so skill `kind: llm` steps can run without a
  /// configured internal provider — the connected client (Claude Desktop
  /// / Code, etc.) does the completion via spec `sampling/createMessage`.
  void attachSampling(SamplingProvider provider) => _sampling = provider;

  /// Bind the host `callTool` so capability-backed skill steps (browser, …)
  /// route to the host's shared engine. See [_runBrowser].
  void bindHostCallTool(
    Future<KernelToolResult> Function(String, Map<String, dynamic>) fn,
  ) => _hostCallTool = fn;

  /// Invoke a host-registered tool by name (the single host endpoint where
  /// ops registers its system/skill tools — `BuiltinToolRegistry`). Used by
  /// the Process/Task runner dispatch and skill-management UI so they reach
  /// the same surface external callers do, instead of a built-in-owned MCP
  /// server (S-LLM-3). Throws if the host handle isn't bound yet.
  Future<KernelToolResult> callHostTool(
    String name,
    Map<String, dynamic> args,
  ) {
    final call = _hostCallTool;
    if (call == null) throw StateError('host callTool not bound');
    return call(name, args);
  }

  /// [callHostTool] + decode the host's JSON-text result to a map (system &
  /// skill tools both `jsonEncode` their result). Returns `{}` for an empty
  /// body, or `{result: <value>}` when the decoded value isn't a map.
  Future<Map<String, dynamic>> callHostToolJson(
    String name,
    Map<String, dynamic> args,
  ) async {
    final result = await callHostTool(name, args);
    final text =
        result.content.whereType<KernelTextContent>().map((c) => c.text).join();
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'result': decoded};
  }

  Future<Map<String, dynamic>> run(
    SkillDefinition def,
    Map<String, dynamic> inputs, {
    String? actorId,
    String? workspaceId,
  }) async {
    final ctx = <String, dynamic>{
      'in': inputs,
      'step': <String, dynamic>{},
      'actor': actorId,
      'workspace': workspaceId,
    };
    return _runAction(def.actionBody, ctx);
  }

  Future<Map<String, dynamic>> _runAction(
    ActionBody body,
    Map<String, dynamic> ctx,
  ) async {
    if (body.kind == 'composite') {
      Map<String, dynamic> lastOutput = {};
      for (final step in body.steps) {
        final result = await _runStep(step, ctx);
        if (step.output != null) {
          (ctx['step'] as Map)[step.output!] = result;
        }
        lastOutput = result;
      }
      return lastOutput;
    }
    final synthetic = ActionStep(
      kind: body.kind,
      data: body.data,
      inputs: body.inputs,
    );
    return _runStep(synthetic, ctx);
  }

  Future<Map<String, dynamic>> _runStep(
    ActionStep step,
    Map<String, dynamic> ctx,
  ) async {
    // Resolve both [inputs] and [data] templates against the current
    // context so handlers can read either without redoing the work.
    // ActionStep is immutable, so wrap in a transient copy with
    // resolved fields.
    final resolved = _resolveMap(step.inputs, ctx);
    final resolvedData = _resolveMap(step.data, ctx);
    final s = ActionStep(
      kind: step.kind,
      id: step.id,
      output: step.output,
      inputs: resolved,
      data: resolvedData,
    );
    switch (s.kind) {
      case 'llm':
        return _runLlm(s, resolved);
      case 'browser':
        return _runBrowser(s, resolved);
      case 'mcp':
        return _runMcp(s, resolved);
      case 'fact.save':
        return _runFactSave(s, resolved);
      case 'fact.query':
        return _runFactQuery(s, resolved);
      case 'ingest':
        return _runIngest(s, resolved);
      case 'channel':
        return _runChannel(s, resolved);
      case 'map':
        return {'value': resolved};
      case 'noop':
        return {};
      default:
        throw StateError('Unsupported action kind: ${s.kind}');
    }
  }

  Future<Map<String, dynamic>> _runLlm(
    ActionStep step,
    Map<String, dynamic> inputs,
  ) async {
    final prompt =
        (step.data['prompt'] as String?) ?? (inputs['prompt'] as String?) ?? '';
    final temperature = (step.data['temperature'] as num?)?.toDouble();
    final maxTokens = (step.data['maxTokens'] as int?) ?? 2000;
    final systemPrompt = step.data['systemPrompt'] as String?;
    // Path 1: internal provider (config_set_llm_provider).
    if (_llm?.hasInternalLlm == true) {
      final req = bundle.LlmRequest(
        prompt: prompt,
        temperature: temperature,
        maxTokens: maxTokens,
      );
      final res = await system.infraPorts.llm!.complete(req);
      return {
        'text': res.content,
        'usage': res.usage,
        'model': res.model,
        'source': 'internal',
      };
    }
    // Path 2: MCP client sampling (server-initiated `sampling/createMessage`).
    if (_sampling != null) {
      final text = await _sampling!(
        prompt: prompt,
        systemPrompt: systemPrompt,
        temperature: temperature,
        maxTokens: maxTokens,
      );
      return {'text': text, 'source': 'sampling'};
    }
    throw StateError(
      'No LLM available. Either configure an internal provider with '
      'config_set_llm_provider, or connect an MCP client that advertises '
      'the `sampling` capability so server-side skills can borrow the '
      'client\'s LLM.',
    );
  }

  Future<Map<String, dynamic>> _runBrowser(
    ActionStep step,
    Map<String, dynamic> inputs,
  ) async {
    final opId =
        (step.data['operation'] as String?) ??
        (inputs['operation'] as String?) ??
        '';
    if (opId.isEmpty) {
      throw ArgumentError('browser step requires `operation`');
    }
    // Route through the host `browser.*` capability (parity rule — built-ins
    // use the host's one shared browser engine, not their own). The host
    // wraps the op output as JSON text content; decode it back to the op map
    // so the skill step's result shape is unchanged.
    final call = _hostCallTool;
    if (call == null) {
      throw StateError('host browser capability not wired');
    }
    final result = await call(
      'browser.$opId',
      Map<String, dynamic>.from(inputs),
    );
    final text =
        result.content.whereType<KernelTextContent>().map((c) => c.text).join();
    final decoded = text.isEmpty ? null : jsonDecode(text);
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{'result': decoded};
  }

  Future<Map<String, dynamic>> _runMcp(
    ActionStep step,
    Map<String, dynamic> inputs,
  ) async {
    final server = step.data['server'] as String?;
    final tool = (step.data['tool'] as String?) ?? (inputs['tool'] as String?);
    if (tool == null) throw ArgumentError('mcp step requires `tool`');
    if (server == null) {
      throw ArgumentError('mcp step requires `server` (the connection id)');
    }
    // Route through the host `mcp.*` capability (kernel `clientHost`-backed,
    // populated via `mcp.connect`) — built-ins drive external MCP servers
    // through the host's one outbound registry, not their own client manager
    // (parity rule). The host wraps the result as JSON text; decode it back to
    // the step's `{content, isError, errorMessage}` shape.
    final call = _hostCallTool;
    if (call == null) throw StateError('host mcp capability not wired');
    final result = await call('mcp.call_tool', <String, dynamic>{
      'id': server,
      'tool': tool,
      'args': Map<String, dynamic>.from(inputs)..remove('tool'),
    });
    final text =
        result.content.whereType<KernelTextContent>().map((c) => c.text).join();
    final decoded = text.isEmpty ? null : jsonDecode(text);
    final map =
        decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
    return {
      'content': map['content'],
      'isError': map['isError'] == true || result.isError == true,
      'errorMessage': map['error'] ?? map['errorMessage'],
    };
  }

  Future<Map<String, dynamic>> _runFactSave(
    ActionStep step,
    Map<String, dynamic> inputs,
  ) async {
    final category =
        (step.data['category'] as String?) ??
        (inputs['category'] as String?) ??
        'misc';
    final key =
        (step.data['key'] as String?) ??
        (inputs['key'] as String?) ??
        'auto_${DateTime.now().millisecondsSinceEpoch}';
    final value =
        inputs.containsKey('content')
            ? inputs['content']
            : (inputs['value'] ?? inputs);
    final knowledge = _knowledge;
    if (knowledge != null) {
      // Persist to BOTH FactGraph and KV via the registry — same path the
      // [knowledge_fact_save] tool uses, so skill-saved and tool-saved
      // facts are queryable through one [knowledge_fact_query].
      await knowledge.saveFact(
        category: category,
        key: key,
        value: value is String ? value : value.toString(),
      );
    } else {
      // Fallback when no registry attached (tests).
      final content = value is String ? value : value.toString();
      await system.facts.extractFragments(content, 'text/plain');
    }
    return {'saved': true, 'category': category, 'key': key};
  }

  Future<Map<String, dynamic>> _runFactQuery(
    ActionStep step,
    Map<String, dynamic> inputs,
  ) async {
    final workspaceId =
        (inputs['workspaceId'] as String?) ??
        (step.data['workspaceId'] as String?) ??
        system.config.workspaceId;
    final rawLimit = inputs['limit'];
    final limit =
        rawLimit is int
            ? rawLimit
            : rawLimit is num
            ? rawLimit.toInt()
            : rawLimit is String
            ? (int.tryParse(rawLimit) ?? 20)
            : 20;
    final q = bundle.FactQuery(
      workspaceId: workspaceId,
      types: (inputs['types'] as List?)?.cast<String>(),
      limit: limit,
    );
    final results = await system.facts.queryFacts(q);
    return {
      'count': results.length,
      'facts': [
        for (final f in results)
          {'id': f.id, 'type': f.type, 'content': f.content},
      ],
    };
  }

  Future<Map<String, dynamic>> _runIngest(
    ActionStep step,
    Map<String, dynamic> inputs,
  ) async {
    final path = (step.data['path'] as String?) ?? (inputs['path'] as String?);
    if (path == null || path.isEmpty) {
      throw ArgumentError('ingest step requires `path`');
    }
    // Chunk via the host `ingest.*` capability, then extract fragments into
    // the flowbrain FactFacade. Both are host-owned — no built-in engine.
    final emitted = await _ingestFileToFacts(File(path));
    return {'fragmentsEmitted': emitted, 'path': path};
  }

  /// Read [file], chunk it with the host `ingest.run` capability, and feed
  /// each chunk into the flowbrain FactFacade (`system.facts`). Shared by the
  /// ingest skill step and the `knowledge_ingest_file` tool — built-ins wire
  /// host capability + host facade, they do not own an ingest engine.
  Future<int> ingestFileToFacts(File file, {String? workspaceId}) =>
      _ingestFileToFacts(file, workspaceId);

  Future<int> _ingestFileToFacts(File file, [String? workspaceId]) async {
    final call = _hostCallTool;
    if (call == null) throw StateError('host ingest capability not wired');
    final content = await file.readAsString();
    final result = await call('ingest.run', <String, dynamic>{
      'content': content,
      'filename': file.path,
    });
    final text =
        result.content.whereType<KernelTextContent>().map((c) => c.text).join();
    final decoded = text.isEmpty ? const <String, dynamic>{} : jsonDecode(text);
    final chunks =
        (decoded is Map ? decoded['chunks'] : null) as List<dynamic>? ??
        const <dynamic>[];
    // Extract fragments per chunk, THEN stage them as review candidates.
    // `extractFragments` is pure extraction — it returns fragments but
    // persists nothing. Without the `createCandidates` call below the
    // extracted knowledge evaporated (candidates.list stayed empty, fact
    // queries returned nothing) even though ingest reported a non-zero
    // count. The origin DDD (`adapt-ingest.md`) specifies the flow as
    // "ingest → Candidate list → Fact confirmed on approval"; this restores the
    // candidate-staging step the migration dropped. Confirmation
    // (`bk.fact.candidates.confirm`) promotes a candidate to a queryable
    // fact — the host facade owns that; the built-in only wires the stage.
    // Tag candidates with the workspace the caller is operating in (the Ops
    // active workspace, threaded from the tool) so they land in the same
    // scope the Ops fact query defaults to (`knowledge_registry.query` uses
    // `kv.workspaceId`). Falling back to `system.config.workspaceId` keeps
    // the skill-step path (no explicit ws) working as before.
    final wsId = workspaceId ?? system.config.workspaceId;
    final candidates = <bundle.CandidateRecord>[];
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (final c in chunks) {
      final t = (c is Map) ? c['text'] as String? : null;
      if (t == null || t.isEmpty) continue;
      try {
        final fragments = await system.facts.extractFragments(t, 'text/plain');
        for (final f in fragments) {
          if (f.text.trim().isEmpty) continue;
          candidates.add(
            bundle.CandidateRecord(
              id: 'ingest-$stamp-${candidates.length}',
              workspaceId: wsId,
              type: 'fact',
              content: <String, dynamic>{'text': f.text},
              confidence: f.confidence,
              createdAt: DateTime.now(),
            ),
          );
        }
      } catch (_) {
        // Skip a chunk that fails to extract and continue.
      }
    }
    if (candidates.isNotEmpty) {
      await system.facts.createCandidates(candidates);
    }
    return candidates.length;
  }

  Future<Map<String, dynamic>> _runChannel(
    ActionStep step,
    Map<String, dynamic> inputs,
  ) async {
    final call = _hostCallTool;
    if (call == null) throw StateError('host channel capability not wired');
    final kind = (inputs['kind'] as String?) ?? 'info';
    final title = inputs['title'] as String? ?? '';
    final body = inputs['body'] as String? ?? '';
    final nid =
        inputs['notificationId'] as String? ??
        'n-${DateTime.now().microsecondsSinceEpoch}';
    final result = await call('channel.send', <String, dynamic>{
      'channelId': 'in_app',
      'conversationId': inputs['recipientId'] ?? '',
      'text': body.isEmpty ? '[$kind] $title' : '[$kind] $title\n$body',
      'replyTo': nid,
    });
    return {
      'notificationId': nid,
      'status': result.isError == true ? 'failed' : 'delivered',
    };
  }

  Map<String, dynamic> _resolveMap(
    Map<String, dynamic> m,
    Map<String, dynamic> ctx,
  ) {
    final out = <String, dynamic>{};
    m.forEach((k, v) => out[k] = _resolveValue(v, ctx));
    return out;
  }

  dynamic _resolveValue(dynamic v, Map<String, dynamic> ctx) {
    if (v is String) return _resolveString(v, ctx);
    if (v is Map) return _resolveMap(Map<String, dynamic>.from(v), ctx);
    if (v is List) return v.map((e) => _resolveValue(e, ctx)).toList();
    return v;
  }

  String _resolveString(String s, Map<String, dynamic> ctx) {
    final re = RegExp(r'\{\{\s*([^}]+)\s*\}\}');
    return s.replaceAllMapped(re, (match) {
      final path = match.group(1)!.trim();
      return _lookupPath(path, ctx)?.toString() ?? '';
    });
  }

  Object? _lookupPath(String path, Map<String, dynamic> ctx) {
    final parts = path.split('.');
    Object? node = ctx;
    for (final p in parts) {
      if (node is Map) {
        node = node[p];
      } else {
        return null;
      }
    }
    return node;
  }
}
